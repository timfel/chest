#!/usr/bin/env ruby

require "optparse"
require "fileutils"

$input = $output = nil
$skip_page_spec = "1,-1"
$paddingpage = -1

OptionParser.new do |opts|
  opts.banner = <<EOF
Usage: pdfbooklet.rb -i INPUT [-o OUTPUT] [-s PAGERANGE]

pdfbooklet.rb can be used to cut and reassemble scanned books so they can
be printed and directly collated and stapled in the center as a booklet.

This program lets "pdftk", "pdfcrop", and "pdfbook" (part of the "pdfjam"
package) to do the actual work so go and get these if you don't have them.

By default such scans have a single cover page, then a sequence of two
consecutive book pages on a single PDF page (the pages facing each other
when the book was put on the scanner) and a single back page. The pages in
the middle hae to be split in half vertically so that each book page is on
a separate PDF page, and then they have to be combined in such a way that
printing a booklet works as desired.

EOF

  opts.on("-i INPUT", "input pdf") { |v| $input = v }
  opts.on("-o OUTPUT", "output pdf") { |v| $output = v }

  opts.on("-p PADDINGPAGE", "which page to duplicate for padding (defaults to last)") { |v| $paddingpage = v.to_i }

  opts.on("-s PAGERANGE", <<EOF) { |v| $skip_page_spec = v }

Page (ranges) to not split in half, because they are not facing pages.
By default this is the first and last page. Page ranges are in the same
format as commonly used by printers: A comma-separated list of single
page numbers or range, e.g.: 1,2,12-15,24.

Negative numbers are possible to count from the end, so the default can
be expressed as 1,-1 and if all pages are already single-page scans, then
1--1 (the second '-' is the unary minus) doesn't separate pages at all.
EOF
end.parse!

if $input.nil?
  puts "No options given. Try --help"
  exit 1
end

$output ||= $input.sub('.pdf', '-booklet.pdf')

raise "Doesn't end with .pdf" unless $input.end_with? ".pdf"

PADDING = 4

def xsystem(*args)
  system(*args).tap { |code| exit(1) unless code }
end

xsystem "pdftk '#{$input}' burst output page_%0#{PADDING}d.pdf"

data = File.read "doc_data.txt"

cnt = 0
data =~ /NumberOfPages:\s+(\d+)/
max_cnt = $1.to_i

skip_range = []
$skip_page_spec.split(",").each do |range|
  if range =~ /(\-?\d+)\-(\-?\d+)/
    start = $1.to_i
    stop = $2.to_i
  else
    start = stop = range.to_i
  end

  start = max_cnt + start + 1 if start < 0
  stop = max_cnt + stop + 1 if stop < 0

  skip_range += (start..stop).to_a
end
skip_range.sort!

puts "Processing #{$input} -> #{$output} with #{max_cnt} pages, skipping #{skip_range.join(',')}"

def cnt_to_pdf(cnt)
  "page_#{cnt.to_s.rjust(PADDING, '0')}.pdf"
end

def cnt_to_single(cnt)
  cnt_to_pdf(cnt).sub("page_", "single_")
end

largest_w = 0
largest_h = 0

data.scan(/PageMediaNumber/) do |str|
  match = $~
  cnt += 1
  next if skip_range.include? cnt
  raise "parsing error" if cnt > max_cnt

  match.post_match =~ /PageMediaDimensions: (\d+\.?\d*) (\d+\.?\d*)/
  width = $1.to_f
  height = $2.to_f
  largest_w = [width, largest_w].max
  largest_h = [height, largest_h].max

  current_file = cnt_to_pdf(cnt)
  left_out = cnt_to_pdf.sub("#{cnt}", "#{cnt}_l")
  right_out = current_file.sub("#{cnt}", "#{cnt}_r")

  xsystem "pdfcrop --margins '0 0 -#{width / 2} 0' #{current_file} #{left_out}"
  xsystem "pdfcrop --margins '-#{width / 2} 0 0 0' #{current_file} #{right_out}"
  File.unlink(current_file)
end

if (padding_pages = 4 - max_cnt % 4) != 0
  # this won't be a good booklet, pad before the last page
  File.rename cnt_to_pdf(max_cnt), cnt_to_pdf(max_cnt + padding_pages)

  $paddingpage = max_cnt + $paddingpage + 1 if $paddingpage < 0
  
  padding_pages.times do |i|
    FileUtils.copy cnt_to_pdf($paddingpage), cnt_to_pdf(max_cnt + i)
  end
end

xsystem "pdftk #{Dir['single_*.pdf'].sort.join(' ')} cat output temp.pdf"

xsystem "pdfbook --suffix book temp.pdf"

File.unlink "temp.pdf"
Dir['page_*.pdf'].each { |pdf| File.unlink pdf }
Dir['single_*.pdf'].each { |pdf| File.unlink pdf }

xsystem "pdfcrop temp-book.pdf temp-book-cropped.pdf"
File.unlink "temp-book.pdf"
File.rename "temp-book-cropped.pdf", $output
puts "Booklet written to #{$output}"
