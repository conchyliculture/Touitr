require 'zip'


class TouitrParser

  def initialize(zip_file)
    raise StandardError, "Please specify an existing zipfile" unless zip_file

    @zip_file = zip_file
    @zip = Zip::File.open(@zip_file)
  end



end
