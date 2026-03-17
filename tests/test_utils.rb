require 'minitest/autorun'
require 'tempfile'
require_relative '../lib/utils'

class TestUtils < Minitest::Test
  def test_join_url
    assert_equal 'https://example.com/path', Utils.join_url('https://example.com', 'path')
    assert_equal 'https://example.com/path', Utils.join_url('https://example.com/', '/path')
    assert_equal 'https://example.com/path', Utils.join_url('https://example.com/', 'path')
    assert_equal 'https://example.com/path', Utils.join_url('https://example.com/', '/path')
    assert_equal 'https://example.com/path/pat/path', Utils.join_url('https://example.com/path/pat', '/path')
  end

  def test_get_media_type
    test_png = File.join(File.dirname(__FILE__), 'test_data', 'test.png')
    type = Utils.get_media_type(test_png)
    assert_equal 'image/png', type

    test_jpg = File.join(File.dirname(__FILE__), 'test_data', 'test.jpg')
    type = Utils.get_media_type(test_jpg)
    assert_equal 'image/jpeg', type

    test_mp4 = File.join(File.dirname(__FILE__), 'test_data', 'bbb.mp4')
    type = Utils.get_media_type(test_mp4)
    assert_equal 'video/mp4', type
  end

  def test_build_twitter_link
    link = Utils.build_twitter_link(handle: 'user', tweet_id: '123', twitter_host: 'notwitter.com')
    assert_equal 'https://notwitter.com/user/status/123', link
  end

  def test_format_number
    assert_equal '1K', Utils.format_number(1000)
    assert_equal '1.5K', Utils.format_number(1500)
    assert_equal '999', Utils.format_number(999)
  end

  def test_highlight_text
    text = 'Hello world'
    highlighted = Utils.highlight_text(text, 'world')
    assert_equal 'Hello <span class="highlight">world</span>', highlighted
    assert_equal 'Hello world', Utils.highlight_text(text, '')
    assert_equal 'Hello world', Utils.highlight_text(text, nil)
  end

  def test_format_date
    timestamp = '2023-01-01T00:00:00.000Z'
    formatted = Utils.format_date(timestamp)
    assert_equal 'Jan 1', formatted
  end

  def test_format_full_timestamp
    timestamp = '2023-01-01T12:30:00.000Z'
    formatted = Utils.format_full_timestamp(timestamp)
    assert_equal 'Jan 1, 2023, 12:30 PM', formatted
  end
end
