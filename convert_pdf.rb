#!/usr/bin/env ruby

require "optparse"
require "fileutils"
require "tempfile"
require "tmpdir"


def xsystem(*args)
  puts args
  system(*args).tap { |code| exit(1) unless code }
end

class Tempfile
  def self.newname(*args, &block)
    Tempfile.create(['mytmp', '.pdf']) do |f|
      path = block.call(f.path)
      if path.respond_to? :to_str
        FileUtils.copy f.path, path
      end
    end
  end
end


class Runner
  attr_accessor :input, :output, :skip_page_spec, :padding_page, :padding_spec,
                :pdf_page_count, :smallest_w, :smallest_h, :pages

  def initialize
    self.skip_page_spec = "1,-1"
    self.padding_page = -1
    self.padding_spec = "split"

    self.smallest_w = 2**32
    self.smallest_h = 2**32
    self.pages = []
  end

  def book_page_count
    pages.size
  end

  PADDING = 4

  def run
    Dir.mktmpdir do |dir|
      xsystem "pdftk '#{input}' burst output #{dir}/page_%0#{PADDING}d.pdf"

      data = File.read "#{dir}/doc_data.txt"

      cnt = 0
      data =~ /NumberOfPages:\s+(\d+)/
      self.pdf_page_count = $1.to_i

      puts "Processing #{input} -> #{output} with #{pdf_page_count} pages, skipping #{skip_range.join(',')}"

      data.scan(/PageMediaNumber/) do |str|
        match = $~
        match.post_match =~ /PageMediaDimensions: (\d+\.?\d*)/
        width = $1.to_f

        cnt += 1
        current_file = "#{dir}/page_#{cnt.to_s.rjust(PADDING, '0')}.pdf"

        raise "parsing error" if cnt > pdf_page_count

        if skip_range.include? cnt
          pages << Page.new(current_file)
        else
          self.pages += Page.new(current_file).split(width)
        end
      end

      pages.each(&:crop)

      self.smallest_w = pages.map(&:width).min
      self.smallest_h = pages.map(&:height).min

      pages.each { |p| p.resize self.smallest_w, self.smallest_h }

      pad_pages

      Tempfile.newname do |tmppath|
        xsystem "pdftk #{page_paths.join(' ')} cat output #{tmppath}"
        xsystem "pdfbook --suffix 'foo' #{tmppath}"
        File.rename File.basename(tmppath).sub(/\.pdf$/, "-foo.pdf"), output
        nil
      end

      puts "Booklet written to #{output}"
    end
  end

  def page_paths
    pages.map(&:path)
  end

  def pad_split?
    padding_spec =~ /split/
  end

  def pad_front?
    padding_spec =~ /front/
  end

  def pad_back?
    padding_spec = /back/
  end

  def pad_pages
    (4 - book_page_count % 4).times do |i|
      if (i % 2 == 0 && pad_split? || pad_front?) .. pad_split?
        pages.insert(1, Page.copy_from(pages[padding_page + 1], i))
      else
        pages.insert(-2, Page.copy_from(pages[padding_page + 1], i))
      end
    end
  end

  def input=(arg)
    if arg.end_with? ".pdf"
      @input = arg
    else
      @input = "#{arg}.pdf"
    end
  end

  def output
    @output || @input.sub(/.pdf$/, "-printable.pdf")
  end

  def skip_page_spec=(arg)
    @skip_page_spec = arg
    @skip_range = nil
  end

  def skip_range
    return @skip_range if @skip_range

    @skip_range = []
    skip_page_spec.split(",").each do |range|
      if range =~ /(\-?\d+)\-(\-?\d+)/
        start = $1.to_i
        stop = $2.to_i
      else
        start = stop = range.to_i
      end

      start = pdf_page_count + start + 1 if start < 0
      stop = pdf_page_count + stop + 1 if stop < 0

      @skip_range += (start..stop).to_a
    end
    @skip_range.sort!
  end

  def self.go
    self.new.go
  end

  def go
    OptionParser.new do |opts|
      opts.banner = <<EOF
Usage: pdfbooklet.rb -i INPUT [-o OUTPUT] [-s PAGERANGE]

pdfbooklet.rb can be used to cut and reassemble scanned books so they can
be printed and directly collated and stapled in the center as a booklet.

This program lets "pdftk", "pdfcrop", "gs", and "pdfbook" (part of the "pdfjam"
package) to do the actual work so go and get these if you don't have them.

By default such scans have a single cover page, then a sequence of two
consecutive book pages on a single PDF page (the pages facing each other
when the book was put on the scanner) and a single back page. The pages in
the middle hae to be split in half vertically so that each book page is on
a separate PDF page, and then they have to be combined in such a way that
printing a booklet works as desired.

EOF

      opts.on("-i INPUT", "input pdf") { |v| @input = v }

      opts.on("-o OUTPUT", "output pdf") { |v| @output = v }

      opts.on("--padding-position POSITION", "where to insert padding: 'front', 'back', 'split'") { |v| @padding_spec = v }

      opts.on("--padding-page PADDINGPAGE", "which BOOK page to duplicate for padding (defaults to last)") { |v| @padding_page = v.to_i }

      opts.on("--single-pages PAGERANGE", <<EOF) { |v| @skip_page_spec = v }

PDF page (ranges) to not split in half, because they are not facing pages.
By default this is the first and last page. Page ranges are in the same
format as commonly used by printers: A comma-separated list of single
page numbers or range, e.g.: 1,2,12-15,24.

Negative numbers are possible to count from the end, so the default can
be expressed as 1,-1 and if all pages are already single-page scans, then
1--1 (the second '-' is the unary minus) doesn't separate pages at all.
EOF
    end.parse!

    if @input.nil?
      puts "No options given. Try --help"
      exit 1
    end

    run
  end
end


class Page
  attr_accessor :path

  def initialize(path)
    @path = path
  end

  def self.copy_from(page, suffix)
    name =  page.path.sub(/\.pdf$/, "_#{suffix}.pdf")
    FileUtils.copy page.path, name
    Page.new(name)
  end

  def width
    return @width if @width
    calculate_dims
    @width
  end

  def height
    return @height if @height
    calculate_dims
    @height
  end

  def calculate_dims
    info = `pdftk #{@path} dump_data`
    info =~ /PageMediaCropRect: (\d+\.?\d*) (\d+\.?\d*) (\d+\.?\d*) (\d+\.?\d*)/
    if $1.nil?
      info =~ /PageMediaRect: (\d+\.?\d*) (\d+\.?\d*) (\d+\.?\d*) (\d+\.?\d*)/
    end
    @left = $1.to_i
    @top = $2.to_i
    @right = $3.to_i
    @bottom = $4.to_i
    @width = @right - @left
    @height = @bottom - @top
  end

  def resize(w, h)
    left_diff = width - w
    top_diff = height - h

    Tempfile.newname do |tmppath|
      xsystem "gs -o #{tmppath} -sDEVICE=pdfwrite -dDEVICEWIDTHPOINTS=#{w} -dDEVICEHEIGHTPOINTS=#{h} -dFIXEDMEDIA #{path}"
      path
    end
  end

  def crop(opts = "")
    Tempfile.newname do |tmppath|
      xsystem "pdfcrop #{opts} #{path} #{tmppath}"
      path
    end
  end

  def split(width)
    lname = path.sub(/\.pdf$/, "_1.pdf")
    rname = path.sub(/\.pdf$/, "_2.pdf")

    FileUtils.copy path, lname
    File.rename path, rname

    left_file = Page.new(lname).crop("--margins '0 0 -#{width / 2} 0'")
    right_file = Page.new(rname).crop("--margins '-#{width / 2} 0 0 0'")

    [left_file, right_file]
  end
end


Runner.go
