# Touitr
Parse your Twitter archive and make it less shitty.

Generates a folder with a statified Twitter-like clone.

| :warning: WARNING           |
|:----------------------------|
| 🚨🚨 ALL THE HTML/CSS/JAVASCRIPT PART IS 99% VIBECODED 🚨🚨    |


## Install

```
$ bundle config set path 'vendor/bundle' ; bundle install
```

## Parse the archive

Go to Twitter and export your data. Wait for a day, and then download the .zip

```
$ bundle exec ruby parse.rb <twitter_archive.zip> <destination_folder>
```

and done! Check out your new website:

```
$ cd <destination_folder> ; ruby -run -e httpd . -p 8000
```

And point your browser to `http://localhost:8000`
