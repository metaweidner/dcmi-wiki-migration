require 'nokogiri'
require 'net/http'
require 'fileutils'
require 'uri'
require 'yaml'

=begin rdoc
Wrap a URI and provide methods for download, parsing, and mirroring of remote HTML document.
=end
class RemoteDocument
  attr_reader :uri, :contents, :img_tags, :links

  def initialize(uri)
    @uri = uri
  end

=begin rdoc
Download, parse, and save the RemoteDocument and
all resources (files, images) in the specified directory.
=end
  def mirror(dir, base_url, image_dir, file_dir, main_page=false)
    @base_url = base_url
    @image_dir = image_dir
    @file_dir = file_dir
    @main_page = main_page
    source = html_get(uri)
    @contents = Nokogiri::HTML(source)
    process_contents
    save_locally(dir)
  end

=begin rdoc
Extract and download image resources from the parsed html document.
=end
  def process_contents
    @img_tags = @contents.xpath( '//img[@src]' )
    @img_tags.each do |tag|
      download_resource(File.join('http://wiki.dublincore.org', tag[:src]), File.join(@image_dir, File.basename(tag[:src])))
    end
    find_links
  end

=begin rdoc
Generate a Hash URL -> Title of all (unique) links in document.
Remove MediaWiki specific '/index.php' & process File links.
=end
  def find_links
    @links = {}
    @contents.xpath('//a[@href]').each do |tag|
      if tag[:href].include? "http://wiki.dublincore.org/index.php"
        tag[:href] = tag[:href].sub("http://wiki.dublincore.org/index.php", "")
        tag[:href] = @base_url + tag[:href] unless tag[:href].include? "File:"
      elsif tag[:href].include? "/index.php"
        tag[:href] = tag[:href].sub("/index.php", "")
        tag[:href] = @base_url + tag[:href] unless tag[:href].include? "File:"        
      end
      if tag[:href].include? "File:"
        if tag.children[0][:src].nil?
          file_name = tag[:href].sub("/File:", "")
          source = html_get(URI.parse(URI.escape(File.join('http://wiki.dublincore.org/index.php', tag[:href]))))
          contents = Nokogiri::HTML(source)
          file_path = contents.xpath("//a[@class='internal']/@href")
          # download_resource(File.join('http://wiki.dublincore.org/index.php', file_path.to_s), File.join(@file_dir, file_name))
          tag[:href] = File.join(@base_url, "files/#{file_name}")
        else
          tag[:href] = File.join(@base_url, "images/#{File.basename(tag.children[0][:src])}")
          tag.children[0][:src] = File.join(@base_url, "images/#{File.basename(tag.children[0][:src])}")
        end
      end
      @links[tag[:href]] = (tag[:title] || '') if (! @links.include? tag[:href])
    end
  end

=begin rdoc
Construct a valid URL for an HREF or SRC parameter. This uses the document URI
to convert a relative URL ('/doc') to an absolute one ('http://foo.com/doc').
=end
  def url_for(str)
    return str if str =~ /^[|[:alpha:]]+:\/\//
    File.join((uri.path.empty?) ? uri.to_s : File.dirname(uri.to_s), str)
  end

=begin rdoc
Send GET to url, following redirects if required.
=end
  def html_get(url)
    resp = Net::HTTP.get_response(url)
    if ['301', '302', '307'].include? resp.code
      url = URI.parse resp['location']
    elsif resp.code.to_i >= 400
      $stderr.puts "[#{resp.code}] #{url}"
      return
    end
    Net::HTTP.get url
  end

=begin rdoc
Attempt to "play nice" with web servers by sleeping for a few ms.
=end
  def delay
    sleep(rand / 100)
  end

=begin rdoc
Download a remote file and save it to the specified path
=end
  def download_resource(url, path)
    FileUtils.mkdir_p File.dirname(path)
    the_uri = URI.parse(URI.escape(url))
    if the_uri
      data = html_get the_uri
      File.open(path, 'wb') { |f| f.write(data) } if data
    end
  end

=begin rdoc
Download all resources to destination directory, rewriting in-document tags
to reflect the new resource location, then save the localized document.
Creates destination directory if it does not exist.
=end
  def save_locally(dir)
    FileUtils.mkdir_p(dir) unless File.exists? dir
   
    # remove HTML BASE tag if it exists
    @contents.xpath('//base').each { |t| t.remove }
    # remove head tag
    @contents.xpath('//head').each { |t| t.remove }
    # remove link tags
    @contents.xpath('//link').each { |t| t.remove }
    # remove script tags
    @contents.xpath('//script').each { |t| t.remove }
    # remove comments
    @contents.xpath('//comment()').each { |t| t.remove }
    # remove mediawiki meta tag
    @contents.xpath('//meta').each { |t| t.remove if t['name'] == "generator" }
    # remove sitesub h3 tag
    @contents.xpath('//h3').each { |t| t.remove if t['id'] == "siteSub" }

    # get lastmod/viewcount values
    @contents.xpath('//li').each do |t|
      if t['id'] == "lastmod"
        @lastmod = t.text.strip
      end
      if t['id'] == "viewcount"
        @viewcount = t.text.strip
      end
    end

    # remove unneeded divs
    @contents.xpath('//div').each do |t|
      t.remove if t['id'] == "column-one"
      t.remove if t['id'] == "footer"
      t.remove if t['id'] == "catlinks"
      t.remove if t['id'] == "contentSub"
      t.remove if t['id'] == "jump-to-nav"
      t.remove if t['class'] == "printfooter"
      t.remove if t['class'] == "visualClear"
    end

    if @main_page == true
      save_path = File.join(dir, "index")
      title = 'Dublin Core Metadata Initiative Media-Wiki Archive'
    else
      save_path = File.join(dir, File.basename(uri.to_s))
      title = File.basename(uri.to_s).gsub("_", " ")
    end
    save_path += '.html' if save_path !~ /\.((html?)|(txt))$/
    File.open(save_path, 'w') { |f| f.write("<!DOCTYPE html>\n<html>\n<head>\n<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">\n<meta http-equiv=\"Content-Language\" content=\"en-us\">\n<title>#{title}</title>\n</head>\n<body>\n<p><b>This is an archived MediaWiki page.</b><br />#{@lastmod}<br />#{@viewcount}</p>\n#{@contents.xpath('//div[@id="bodyContent"]').to_html}\n</body>\n</html>") }
    # File.open(save_path, 'w') { |f| f.write("---\nlayout: page\ntitle: #{title}\n---\n\n#{@contents.xpath('//div[@id="bodyContent"]').to_html}") }
  end
end

def process_hierarchy(dir, base_url, image_dir, file_dir, section)
  section_dir = File.join(dir, section['name'])
  if section['root']
    puts "processing #{section['root']}"
    doc = RemoteDocument.new(URI.parse(URI.escape(section['root'])))
    doc.mirror(dir, base_url, image_dir, file_dir)
  else
    puts "processing #{section['name']}"
    FileUtils.mkdir_p(section_dir) unless File.exists? section_dir
  end
  if section['children']
    section['children'].each do |url|
      puts "processing #{url}"
      doc = RemoteDocument.new(URI.parse(URI.escape(url)))
      doc.mirror(section_dir, base_url, image_dir, file_dir)
    end
  end
  if section['sections']
    section['sections'].each { |section| process_hierarchy(section_dir, base_url, image_dir, file_dir, section) }
  end
end

if __FILE__ == $0
  if ARGV.count < 2
    $stderr.puts "Usage: #{$0} YAML_URL_FILE DIR"
    exit 1
  end

  yaml_file = YAML::load(IO.read(ARGV.shift))
  @dir = ARGV.shift

  base_url = yaml_file['base_url']
  image_dir = yaml_file['image_dir']
  file_dir = yaml_file['file_dir']
  puts "processing #{yaml_file['index']}"
  doc = RemoteDocument.new(URI.parse(URI.escape(yaml_file['index'])))
  doc.mirror(@dir, base_url, image_dir, file_dir, true)

  yaml_file['children'].each do |url|
    puts "processing #{url}"
    doc = RemoteDocument.new(URI.parse(URI.escape(url)))
    doc.mirror(@dir, base_url, image_dir, file_dir)
  end

  yaml_file['sections'].each { |section| process_hierarchy(@dir, base_url, image_dir, file_dir, section) } if yaml_file['sections']
end
