#!/usr/bin/env ruby
# Checks this repository's files offline, with only Ruby's standard library (no installs, no network):
#   1. every YAML file parses;
#   2. issue forms (.github/ISSUE_TEMPLATE/*.yml) have the shape GitHub needs to show them;
#   3. the issue chooser config (.github/ISSUE_TEMPLATE/config.yml) is well formed;
#   4. the organisation profile (profile/README.md) exists, and every local file a Markdown file
#      links to (links, images, HTML src/href) exists.
# Run from anywhere: ruby scripts/check-repo.rb. Exits 1 and lists each problem when anything is wrong.
require "yaml"

# ci-local runs this in a cleared environment (no LANG), where Ruby would read files as US-ASCII and stop on the
# first non-ASCII character. The repo's files are UTF-8.
Encoding.default_external = Encoding::UTF_8

ROOT = File.expand_path("..", __dir__)
Dir.chdir(ROOT)
problems = []
checked = 0
md_count = 0

yaml_files = Dir.glob("**/*.{yml,yaml}", File::FNM_DOTMATCH).reject { |f| f.start_with?(".git/") }.sort
docs = {}
yaml_files.each do |f|
  checked += 1
  begin
    docs[f] = YAML.safe_load(File.read(f, encoding: "UTF-8"))
  rescue Psych::Exception => e
    problems << "#{f}: YAML does not parse: #{e.message}"
  end
end

FIELD_TYPES = %w[markdown textarea input dropdown checkboxes].freeze
str = ->(v) { v.is_a?(String) && !v.strip.empty? }

Dir.glob(".github/ISSUE_TEMPLATE/*.{yml,yaml}").sort.each do |f|
  next if File.basename(f, ".*") == "config"
  next unless docs.key?(f)
  form = docs[f]
  checked += 1
  unless form.is_a?(Hash)
    problems << "#{f}: issue form must be a mapping"
    next
  end
  %w[name description].each { |k| problems << "#{f}: '#{k}' must be a non-empty string" unless str.(form[k]) }
  body = form["body"]
  unless body.is_a?(Array) && !body.empty?
    problems << "#{f}: 'body' must be a non-empty list"
    next
  end
  ids = []
  body.each_with_index do |item, i|
    at = "#{f}: body[#{i}]"
    unless item.is_a?(Hash) && FIELD_TYPES.include?(item["type"])
      problems << "#{at}: 'type' must be one of #{FIELD_TYPES.join(', ')}"
      next
    end
    attrs = item["attributes"]
    unless attrs.is_a?(Hash)
      problems << "#{at}: 'attributes' must be a mapping"
      next
    end
    if item["type"] == "markdown"
      problems << "#{at}: markdown needs 'attributes.value'" unless str.(attrs["value"])
      next
    end
    problems << "#{at}: #{item['type']} needs 'attributes.label'" unless str.(attrs["label"])
    if item.key?("id")
      id = item["id"].to_s
      problems << "#{at}: id '#{id}' may only use letters, digits, - and _" unless id.match?(/\A[A-Za-z0-9_-]+\z/)
      problems << "#{at}: id '#{id}' is used twice" if ids.include?(id)
      ids << id
    end
    opts = attrs["options"]
    case item["type"]
    when "dropdown"
      problems << "#{at}: dropdown needs a non-empty 'attributes.options' list" unless opts.is_a?(Array) && !opts.empty?
    when "checkboxes"
      unless opts.is_a?(Array) && !opts.empty? && opts.all? { |o| o.is_a?(Hash) && str.(o["label"]) }
        problems << "#{at}: checkboxes need 'attributes.options', each with a 'label'"
      end
    end
  end
end

Dir.glob(".github/ISSUE_TEMPLATE/config.{yml,yaml}").each do |f|
  next unless docs.key?(f)
  cfg = docs[f]
  checked += 1
  unless cfg.is_a?(Hash)
    problems << "#{f}: must be a mapping"
    next
  end
  if cfg.key?("blank_issues_enabled") && ![true, false].include?(cfg["blank_issues_enabled"])
    problems << "#{f}: 'blank_issues_enabled' must be true or false"
  end
  Array(cfg["contact_links"]).each_with_index do |link, i|
    at = "#{f}: contact_links[#{i}]"
    unless link.is_a?(Hash)
      problems << "#{at}: must be a mapping"
      next
    end
    %w[name url about].each { |k| problems << "#{at}: '#{k}' must be a non-empty string" unless str.(link[k]) }
    problems << "#{at}: url must start with https://" if str.(link["url"]) && !link["url"].start_with?("https://")
  end
end

problems << "profile/README.md is missing (GitHub shows it on the organisation page)" unless File.file?("profile/README.md")

Dir.glob("**/*.md", File::FNM_DOTMATCH).reject { |f| f.start_with?(".git/") }.sort.each do |f|
  checked += 1
  md_count += 1
  text = File.read(f, encoding: "UTF-8").gsub(/```.*?```/m, "")
  targets = text.scan(/!?\[[^\]]*\]\(\s*<?([^)\s>]+)/).flatten + text.scan(/\b(?:src|href)\s*=\s*["']([^"']+)["']/i).flatten
  targets.each do |t|
    next if t.match?(%r{\A(?:[a-z][a-z0-9+.-]*:|//|#)}i)
    path = t.sub(/[?#].*\z/, "")
    next if path.empty?
    full = path.start_with?("/") ? File.join(ROOT, path) : File.join(File.dirname(f), path)
    problems << "#{f}: links to '#{t}', which does not exist" unless File.exist?(full)
  end
end

if problems.empty?
  puts "check-repo: #{checked} checks pass, 0 fail (#{yaml_files.size} YAML files, #{md_count} Markdown files)"
else
  puts problems
  puts "check-repo: #{problems.size} problem(s) found"
  exit 1
end
