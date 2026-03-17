require 'marcel'
require 'nokogiri'
require 'time'

module Utils
  DEFAULT_TWITTER_HOST = 'fxtwitter.com'
  def self.join_url(first, second)
    "#{first.gsub(/\/+$/, '')}/#{second.sub(/^\/+/, '')}"
  end

  def self.get_media_type(file_path)
    io = File.open(file_path)
    type = Marcel::MimeType.for(io)
    io.close
    return type
  end

  def self.build_twitter_link(handle: nil, tweet_id: nil, twitter_host: DEFAULT_TWITTER_HOST)
    return "https://#{twitter_host}/#{handle}/status/#{tweet_id}"
  end

  def self.format_number(num)
    if num.to_i >= 1_000_000
      return "#{(num.to_i / 1_000_000.0).round(1)}M".gsub(/\.0M$/, 'M') # Remove .0 for whole
    elsif num.to_i >= 1_000
      return "#{(num.to_i / 1_000.0).round(1)}K".gsub(/\.0K$/, 'K') # Remove .0 for whole numbers
    else
      return num.to_s
    end
    res

  end

  def self.highlight_text(text, query)
    return text if query.nil? || query.empty?

    # Simple regex substitution matching the JS logic
    text.gsub(/(#{Regexp.escape(query)})/i, '<span class="highlight">\1</span>')
  end

  def self.format_date(timestamp)
    # Placeholder: Implement your Ruby date formatting here
    Time.parse(timestamp).strftime('%b %-d')
  end

  def self.format_full_timestamp(timestamp)
    # Placeholder: Implement your Ruby full date formatting here
    Time.parse(timestamp).strftime('%b %-d, %Y, %I:%M %p')
  end
end
