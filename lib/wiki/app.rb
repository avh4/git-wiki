%w(rubygems sinatra/base sinatra/extensions git haml
sass logger wiki/extensions wiki/utils
wiki/object wiki/helper wiki/user wiki/engine wiki/cache wiki/mime wiki/plugin).each { |dep| require dep }

module Wiki
  # Main class of the application
  class App < Sinatra::Application
    include Helper
    include Utils

    # Sinatra options
    set :patterns, :path => PATH_PATTERN, :sha => SHA_PATTERN
    set :haml, :format => :xhtml, :attr_wrapper  => '"', :ugly => true
    set :root, lambda { Config.root }
    set :static, false
    set :raise_errors, false
    set :dump_errors, true
    set :logging, false
    set :methodoverride, false

    def initialize(app = nil, opts = {})
      super(app)

      @logger = opts[:logger] || Logger.new(nil)
      @logger.info self.class.dump_routes

      if File.exists?(Config.git.repository) && File.exists?(Config.git.workspace)
        @logger.info 'Opening repository'
        @repo = Git.open(Config.git.workspace, :repository => Config.git.repository,
                         :index => File.join(Config.git.repository, 'index'), :log => @logger)
      else
        @logger.info 'Initializing repository'
        @repo = Git.init(Config.git.workspace, :repository => Config.git.repository,
                         :index => File.join(Config.git.repository, 'index'), :log => @logger)
        page = Page.new(@repo, Config.main_page)
        page.write('This is the main page of the wiki.', 'Initialize Repository')
        @logger.info 'Repository initialized'
      end

      Plugin.logger = @logger
      Plugin.dir = File.join(App.root, 'plugins')
      Plugin.load('*')
      Plugin.start
    end

    # Executed before each request
    before do
      start_timer
      @logger.debug request.env

      content_type 'application/xhtml+xml', :charset => 'utf-8'

      forbid('No ip given' => !request.ip)
      @user = session[:user] || User.anonymous(request.ip)
    end

    # Handle 404s
    not_found do
      if request.env['wiki.redirect_to_new']
        # Redirect to create new page if flag is set
        redirect(params[:sha] ? params[:path].urlpath : (params[:path]/'new').urlpath)
      else
        @error = request.env['sinatra.error'] || Sinatra::NotFound.new
        haml :error
      end
    end

    # Show wiki error page
    error do
      @error = request.env['sinatra.error']
      @logger.error @error
      haml :error
    end

    get '/sys/fragments/user' do
      haml :'fragments/user', :layout => false
    end

    get '/sys/fragments/sidebar' do
      if page = Page.find(@repo, 'Sidebar')
        engine = Engine.find!(page)
        if engine.layout?
          #cache_control :etag => page.commit.sha, :last_modified => page.latest_commit.date
          cache_control :max_age => 120
          engine.render(page)
        else
          '<span class="error">No engine found for Sidebar</span>'
        end
      else
        '<a href="/Sidebar/new">Create Sidebar</a>'
      end
    end

    get '/' do
      redirect Config.main_page.urlpath
    end

    get '/login', '/signup' do
      cache_control :static => true
      haml :login
    end

    post '/login' do
      begin
        session[:user] = User.authenticate(params[:user], params[:password])
        redirect '/'
      rescue MessageError => error
        message :error, error.message
        haml :login
      end
    end

    post '/signup' do
      begin
        session[:user] = User.create(params[:user], params[:password],
                                     params[:confirm], params[:email])
        redirect '/'
      rescue MessageError => error
        message :error, error.message
        haml :login
      end
    end

    get '/logout' do
      session[:user] = @user = nil
      redirect '/'
    end

    get '/profile' do
      haml :profile
    end

    post '/profile' do
      if !@user.anonymous?
        begin
          @user.modify do |user|
            user.change_password(params[:oldpassword], params[:password], params[:confirm]) if !params[:password].blank?
            user.email = params[:email]
          end
          message :info, 'Changes saved'
          session[:user] = @user
        rescue MessageError => error
          message :error, error.message
        end
      end
      haml :profile
    end

    get "/:style.css" do
      begin
        # Try to use wiki version
        params[:output] = 'css'
        params[:path] = params[:style] + '.sass'
        show
      rescue Object::NotFound
        raise if !%w(screen print reset).include?(params[:style])
        # Fallback to default style
        cache_control :max_age => 120
        content_type 'text/css', :charset => 'utf-8'
        sass :"style/#{params[:style]}", :sass => {:style => :compact}
      end
    end

    get '/commit/:sha' do
      cache_control :etag => params[:sha], :validate_only => true
      @commit = @repo.gcommit(params[:sha])
      cache_control :etag => @commit.sha, :last_modified => @commit.date
      @diff = @repo.diff(@commit.parent, @commit.sha)
      haml :commit
    end

    get '/?:path?/archive' do
      @tree = Tree.find!(@repo, params[:path])
      cache_control :etag => @tree.sha, :last_modified => @tree.commit.date
      content_type 'application/x-tar-gz'
      attachment "#{@tree.safe_name}.tar.gz"
      archive = @tree.archive
      begin
        # See send_file
        response['Content-Length'] ||= File.stat(archive).size.to_s
        halt StaticFile.open(archive, 'rb')
      rescue Errno::ENOENT
        not_found
      end
    end

    get '/?:path?/history' do
      @object = Object.find!(@repo, params[:path])
      cache_control :etag => @object.sha, :last_modified => @object.commit.date
      haml :history
    end

    get '/?:path?/diff' do
      begin
        @object = Object.find!(@repo, params[:path])
        forbid('From not selected' => params[:from].blank?, 'To not selected' => params[:to].blank?)
        cache_control :static => true
        @diff = @object.diff(params[:from], params[:to])
        haml :diff
      rescue MessageError => error
        message :error, error.message
        haml :history
      end
    end

    get '/:path/edit', '/:path/upload' do
      begin
        @page = Page.find!(@repo, params[:path])
        haml :edit
      rescue Object::NotFound
        pass if action? :upload # Pass to next handler because /upload is used twice
        raise
      end
    end

    get '/new', '/upload', '/:path/new', '/:path/upload' do
      begin
        # Redirect to edit for existing pages
        if !params[:path].blank? && Object.find(@repo, params[:path])
          redirect (params[:path]/'edit').urlpath
        end
        @page = Page.new(@repo, params[:path])
        boilerplate @page
        forbid('Path is not allowed' => name_clash?(params[:path]))
      rescue MessageError => error
        message :error, error.message
      end
      haml :new
    end

    get '/:sha', '/:path/:sha', '/:path' do
      begin
        pass if name_clash?(params[:path])
        show
      rescue Object::NotFound
        request.env['wiki.redirect_to_new'] = true
        pass
      end
    end

    # Edit form sends put requests
    put '/:path' do
      @page = Page.find!(@repo, params[:path])
      begin
        if action?(:upload) && params[:file]
          @page.write(params[:file][:tempfile], 'File uploaded', @user.author)
        elsif action?(:edit) && params[:content]
          preview(:edit, params[:content])
          content = if params[:pos]
                      pos = [[0, params[:pos].to_i].max, @page.content.size].min
                      len = params[:len] ? [0, params[:len].to_i].max : @page.content.size - params[:len]
                      @page.content[0,pos].to_s + params[:content] + @page.content[pos+len..-1].to_s
                    else
                      params[:content]
                    end
          @page.write(content, params[:message], @user.author)
        else
          redirect((@page.path/'edit').urlpath)
        end
        redirect @page.path.urlpath
      rescue MessageError => error
        message :error, error.message
        haml :edit
      end
    end

    # New form sends post request
    post '/', '/:path' do
      begin
        @page = Page.new(@repo, params[:path])
        if action?(:upload) && params[:file]
          forbid('Path is not allowed' => name_clash?(@page.path))
          @page.write(params[:file][:tempfile], "File #{@page.path} uploaded", @user.author)
        elsif action?(:new)
          preview(:new, params[:content])
          forbid('Path is not allowed' => name_clash?(@page.path))
          @page.write(params[:content], params[:message], @user.author)
        else
          redirect '/new'
        end
        redirect @page.path.urlpath
      rescue MessageError => error
        message :error, error.message
        haml :new
      end
    end

    private

    def preview(template, content)
      if params[:preview]
        message(:error, 'Commit message is empty') if params[:message].empty?
        message(:error, 'Path is not allowed') if name_clash?(@page.path)
        @page.preview_content = content
        if @page.mime.text?
          engine = Engine.find!(@page)
          @preview = engine.render(@page) if engine.layout?
        end
        halt haml(template)
      end
    end

    def name_clash?(path)
      path = path.to_s.urlpath
      patterns = self.class.routes.values.inject([], &:+).map {|x| x[0] }.uniq

      # Remove overly general patterns
      patterns.delete(%r{.*[^\/]$}) # Sinatra static files
      patterns.delete(%r{^/(#{PATH_PATTERN})$}) # Path
      patterns.delete(%r{^/(#{PATH_PATTERN})/(#{SHA_PATTERN})$}) # Path with unstrict sha
      patterns.delete(%r{^/(#{SHA_PATTERN})$}) # Root with unstrict sha

      # Add pattern to ensure availability of strict sha urls
      # Shortcut sha urls (e.g /Beef) can be overridden
      patterns << %r{^/(#{STRICT_SHA_PATTERN})$}
      patterns << %r{^/(#{PATH_PATTERN})/(#{STRICT_SHA_PATTERN})$}

      patterns.any? {|pattern| pattern =~ path }
    end

    # Show page or tree
    def show
      cache_control :etag => params[:sha], :validate_only => true
      object = Object.find!(@repo, params[:path], params[:sha])

      if object.tree?
        root = Tree.find!(@repo, '/', params[:sha])
        cache_control :etag => root.commit.sha, :last_modified => root.commit.date

        @tree = object
        @children = walk_tree(root, params[:path].to_s.cleanpath.split('/'), 0)
        haml :tree
      else
        cache_control :etag => object.latest_commit.sha, :last_modified => object.latest_commit.date

        @page = object
        engine = Engine.find!(@page, params[:output])
        @content = engine.render(@page, params)
        if engine.layout?
          haml :page
        else
          content_type engine.mime(@page).to_s
          @content
        end
      end
    end

    # Walk tree and return array with level counter
    def walk_tree(tree, path, level)
      result = []
      tree.children.each do |child|
        open = child.tree? && (child.path == path[0..level].join('/'))
        result << [level, child, open]
        result += walk_tree(child, path, level + 1) if open
      end
      result
    end

    # Boilerplate for new pages
    def boilerplate(page)
      if page.path =~ /^\w+\.sass$/
        name = File.join(Config.root, 'views', 'style', $&)
        page.content = File.read(name) if File.file?(name)
      end
    end

  end
end
