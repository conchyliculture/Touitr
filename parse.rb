require 'json'
require 'net/http'
require 'pry'
require 'zip'

class TouitrParser
  CACHE_DIR = '.cache'.freeze
  IMAGES_DIR_NAME = 'images'.freeze
  TWITTER_HOST = 'fxtwitter.com'.freeze

  def initialize(zip_file, destination_directory)
    raise StandardError, "Please specify an existing zipfile" unless zip_file

    @destination_directory = destination_directory
    unless Dir.exist?(@destination_directory)
      Dir.mkdir(@destination_directory)
    end

    @pics_directory = File.join(@destination_directory, IMAGES_DIR_NAME)

    unless File.exist?(@pics_directory)
      Dir.mkdir(@pics_directory)
    end

    @zip_file = zip_file
    @zip = Zip::File.open(@zip_file)

    unless Dir.exist?(CACHE_DIR)
      Dir.mkdir(CACHE_DIR)
    end

    @tco_links_cache_path = File.join(CACHE_DIR, 'links')
    @tco_links_cache = {}
    if File.exist?(@tco_links_cache_path)
      @tco_links_cache = JSON.parse(File.read(@tco_links_cache_path))
    end
  end

  def update_tco_cache(from, to)
    @tco_links_cache[from] = to
    f = File.open(@tco_links_cache_path, 'w')
    f.write(JSON.pretty_generate(@tco_links_cache))
    f.close
  end

  def resolve_tco(url)
    return @tco_links_cache[url] if @tco_links_cache[url]

    $stdout.write("Resolving #{url}.... ")
    resp = Net::HTTP.get_response(URI(url))
    if resp.code == "301"
      update_tco_cache(url, resp['location'])
      $stdout.puts(resp['location'])
      return resp['location']
    else
      raise StandardError, "Unexpected response code #{resp.code} from trying to resolve link #{url}"
    end
  end

  def build_twitter_link(handle: nil, tweet_id: nil)
    return "https://#{TWITTER_HOST}/#{handle}/status/#{tweet_id}"
  end

  def get_archive_username()
    json = javascript_to_json('data/account.js')
    json[0]['account']['username']
  end

  def get_archive_userid()
    json = javascript_to_json('data/account.js')
    json[0]['account']['accountId']
  end

  def get_archive_displayname()
    json = javascript_to_json('data/account.js')
    json[0]['account']['accountDisplayName']
  end

  def get_archive_avatar()
    json = javascript_to_json('data/profile.js')
    url = json[0]['profile']['avatarMediaUrl']

    if url.start_with?("https://")
      frag = url.split('/')
      prof_file = @zip.glob("data/profile_media/*#{frag[-1]}*")[0]
      url = File.join(@pics_directory, 'profile.jpg')
      extract_file(prof_file, File.join(@pics_directory, 'profile.jpg'))
      return File.join(IMAGES_DIR_NAME, 'profile.jpg')
    end
    return url
  end

  def find_media(pattern)
    results = @zip.glob("data/tweets_media/*#{pattern}*")

    if results.size == 1
      return results[0].name
    elsif results.empty?
      raise StandardError, "Could not find a media with pattern *#{pattern}*"
    else
      raise StandardError, "Found more than one media with pattern *#{pattern}*"
    end
  end

  def extract_file(zip_path, destination)
    if File.exist?(destination)
      puts "File #{destination} already exists, skipping extraction"
      return
    end
    File.new(destination, 'w+').write(@zip.read(zip_path))
  end

  def javascript_to_json(js_file)
    tweets_file = @zip.read(js_file)
    j = JSON.parse(tweets_file.sub(/\A[^\[{]*=/, '').strip.chomp(';'))
    return j
  end

  def clean_tweet_content(tweet)
    tweet['full_text'] = tweet['full_text'].gsub(/https:\/\/t.co\/[^\s]{10}/) do |x|
      d = resolve_tco(x)
      "<a href='#{d}'>#{d}</a>"
    end

    tweet['entities']['user_mentions'].each do |um|
      tweet['full_text'].gsub!("@#{um['screen_name']}", "<a href='https://twitter.com/#{um['screen_name']}'>@#{um['screen_name']}</a>")
    end

    if tweet['extended_entities']
      tweet['extended_entities']['media'].each do |m|
        # We don't need the link to the media
        tweet['full_text'].gsub!(m['expanded_url'].gsub('x.com', 'twitter.com'), '')
      end
    end

    tweet['full_text'].gsub!("\n", "<br/>")
    return tweet['full_text']
  end

  def tweets_to_json
    archive_owner = {
      'handle' => get_archive_username(),
      'displayname' => get_archive_displayname(),
      'avatar' => get_archive_avatar(),
      'id' => get_archive_userid()
    }
    res = []
    javascript_to_json('data/tweets.js').each do |t|
      tweet = t['tweet']

      begin
        info = {
          'avatar' => archive_owner['avatar'],
          'replies' => 0,
          'retweets' => 0,
          'likes' => 0,
          'author' => archive_owner['displayname'],
          'handle' => archive_owner['handle'],
          "id" => tweet['id'],
          "timestamp" => tweet['created_at'],
          "type" => tweet['type'] || 'default'
        }

        if tweet['full_text'].start_with?('RT @')
          info['isRetweet'] = true
          info['retweetedBy'] = archive_owner['displayname']
          info['avatar'] = ''
          info['author'] = tweet['full_text'].scan(/RT @([^\s]+):/)[0][0]
          tweet['full_text'] = tweet['full_text'].delete_prefix("RT @#{info['author']}: ")
        elsif tweet['in_reply_to_status_id'] =~ /^\d+$/
          reply_to_id = tweet['in_reply_to_user_id_str']
          if reply_to_id == archive_owner['id']
            info["replyTo"] = build_twitter_link(handle: archive_owner['handle'], tweet_id: tweet['in_reply_to_status_id'])
            info["replyToAuthor"] = archive_owner['handle']
          else
            reply_to_ent = tweet['entities']['user_mentions'].select { |um| um['id'] == reply_to_id }[0]
            if reply_to_ent
              reply_to_handle = reply_to_ent['screen_name']
              info["replyTo"] = build_twitter_link(handle: reply_to_handle, tweet_id: tweet['in_reply_to_status_id'])
              info["replyToAuthor"] = tweet['in_reply_to_screen_name']
            elsif tweet['full_text'].start_with?('@')
              reply_to_handle = tweet['full_text'].scan(/^@([^ ]+)/)[0][0]
              tweet['full_text'] = tweet['full_text'].delete_prefix("@#{reply_to_handle} ")
              info["replyTo"] = build_twitter_link(handle: reply_to_handle, tweet_id: tweet['in_reply_to_status_id'])
              info["replyToAuthor"] = tweet['in_reply_to_screen_name']
            else
              raise StandardError, "Couldn't find who this tweet was a reply to : #{tweet}"
            end
          end
        end

        if tweet['extended_entities']
          info['media'] = tweet['extended_entities']['media'].map do |m|
            case m['type']
            when 'photo'
              m_url = m['media_url_https']
              m_zip_path = find_media("#{tweet['id']}*#{m_url.split('/')[-1]}*")
            when 'video'
              m_zip_path = find_media(tweet['id_str'])
            when 'animated_gif'
              m_zip_path = find_media(tweet['id_str'])
            else
              raise StandardError, "Unsupported extended_entities media type #{m['type']}"
            end
            dest_image_filename = File.basename(m_zip_path)
            extract_file(m_zip_path, File.join(@pics_directory, dest_image_filename))
            item = "/#{IMAGES_DIR_NAME}/#{dest_image_filename}"

            item
          end

        elsif tweet['entities']['media']
          info['media'] = tweet['entities']['media'].map do |m|
            m_url = m['media_url_https']
            m_zip_path = find_media(m_url.split('/')[-1])
            dest_image_filename = File.basename(m_zip_path)
            extract_file(m_zip_path, File.join(@pics_directory, dest_image_filename))

            "/#{IMAGES_DIR_NAME}/#{dest_image_filename}"
          end
        end

        info['content'] = clean_tweet_content(tweet)
      rescue StandardError => e
        puts e.backtrace
        puts e
        binding.pry
      end

      res << info
    end

    out = File.open("#{@destination_directory}/posts.json", 'w')
    out.write(JSON.pretty_generate(res))
    out.close
  end
end

t = TouitrParser.new(ARGV[0], 'assets')

t.tweets_to_json
