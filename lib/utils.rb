require 'marcel'
require 'nokogiri'
require 'progressbar'
require 'time'

class ProgressBar
  class Base
    attr_accessor :logger

    alias original_initialize initialize
    def initialize(*args)
      @logger = Logger.new self
      original_initialize(*args)
    end
  end

  class Logger < ::Logger
    alias original_initialize initialize
    def initialize(progress_bar) # rubocop:disable Lint/MissingSuper
      @progress_bar = progress_bar
      original_initialize nil
    end

    def add(severity, message = nil, progname = nil, &_block)
      severity ||= UNKNOWN
      return true if severity < @level

      progname ||= @progname
      if message.nil?
        if block_given?
          message = yield
        else
          message = progname
          progname = @progname
        end
      end
      @progress_bar.log format_message(format_severity(severity), ::Time.now, progname, message)
      true
    end
  end
end

module Utils
  DEFAULT_TWITTER_HOST = 'fxtwitter.com'.freeze
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
