require 'git_support'

class TC_Page < Test::Unit::TestCase
  include GitSupport

  def test_extension
    assert_equal 'path/name.ext', Wiki::Page.new(@repo, '/path/name.ext').path
  end

  def test_write
    page = Wiki::Page.new(@repo, 'test')
    assert page.new?
    assert !page.saved?
    assert_nil page.content
    assert_nil page.saved_content
    page.write('old content', "message1\ntext", 'Author1 <author1@localhorst>')

    assert_equal 'old content', page.content
    assert_equal 'old content', page.saved_content
    assert !page.new?
    assert page.saved?

    assert_equal "message1\ntext", page.commit.message
    assert_equal 'Author1', page.commit.author.name
    assert_equal 'author1@localhorst', page.commit.author.email

    page.content = 'new content'
    assert !page.new?
    assert !page.saved?
    assert_equal 'new content', page.content
    assert_equal 'old content', page.saved_content
    page.save('message2', 'Author2 <author2@localhorst>')

    assert_equal 'message2', page.commit.message
    assert_equal 'Author2', page.commit.author.name
    assert_equal 'author2@localhorst', page.commit.author.email

    page = Wiki::Page.find!(@repo, 'test')
    assert !page.new?
    assert_equal 'new content', page.content

    assert_equal 'message2', page.commit.message
    assert_equal 'Author2', page.commit.author.name
    assert_equal 'author2@localhorst', page.commit.author.email
  end

  def test_duplicate
    page = Wiki::Page.new(@repo, 'test')
    page.write('content', 'message', 'Author <author@localhorst>')

    page = Wiki::Page.new(@repo, 'test')
    assert_raise Wiki::MessageError do
      page.write('content', 'message', 'Author <author@localhorst>')
    end
  end
end
