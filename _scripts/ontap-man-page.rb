require 'nokogiri'
require 'fileutils'
require 'json'
require 'yaml'
require 'pathname'

###########
# Required Env variables
# CLI_INPUT: The full path to the source man pages
# CLI_INPUT_TEMPLATE_FILE: The full path to yml base file with `section cli` tag to replace with command list
# CLI_OUTPUT: The path to the destination folder
###########

EXTRACT_XML=false

# MAXIMUM MENU DEPTH
@menu_depth = ENV['CLI_MENU_DEPTH'].nil? ? 2 : ENV['CLI_MENU_DEPTH'].to_i

def traverse_files()
  index = Nokogiri::XML.parse(File.read(File.join(@input_dir,'man_index.xml')))

  # Collect inventory of all commands to be published
  index.search('/index/commands/command').each do |command|
    command_name = command.at_xpath('name').text
    privilege_value = command.at_xpath('privilege_value').text.to_i
    if privilege_value < 2
      @commands.push(command_name)
      extract(command.at_xpath('html-path').text) if EXTRACT_XML
    end
  end

  convert_xml(index) unless EXTRACT_XML
end

##
# Convert commands from xml to AsciiDoc
#
def convert_xml(index)
  puts "Converting #{@commands.length} commands"
  index.search('/index/commands/command').each do |command|
    relative_html_path = command.at_xpath('html-path').text 
    xml_path = input_xml_path(relative_html_path)
    privilege_value = command.at_xpath('privilege_value').text.to_i
    @index_command = command.at_xpath('name').text
    @relative_links = []
    begin
      convert_document(xml_path) if privilege_value < 2
    rescue RuntimeError => e 
      puts "WARN: #{e.message}"
    end

    # exit 0 if "#{@index_command}" == "cluster join"
  end
end

def write_sidebar(template_file, output_name)
  full_output_path = "#{@output_doc_path}/#{output_name}"
  template_sidebar = [] if template_file.nil?
  template_sidebar = (!template_file['sidebar'].nil?) ? template_file['sidebar'] : template_file    

  found = find_and_replace(template_sidebar, 'section', 'cli', @sidebar_entries)
  if found 
    puts 'section cli found and replaced'
    File.open(full_output_path, "w") { |yfile| yfile.write(template_file.to_yaml) }
  else
    puts 'WARN: section cli not found - writing content to empty file'
    sidebar = {'title' => 'Command man pages', 'entries' => @sidebar_entries}
    File.open(full_output_path, "w") { |yfile| yfile.write(sidebar.to_yaml) }
  end
end

def extract(relative_html_path)
  out_xml_file = output_xml_path(relative_html_path)
  in_xml_file = input_xml_path(relative_html_path)
  FileUtils.mkdir_p(File.dirname("#{out_xml_file}"))
  FileUtils.cp("#{in_xml_file}", "#{out_xml_file}")
end

def get_text(document, xpath, file)
  node = document.at_xpath(xpath)
  if(!node)
    puts "WARN: Unable to retrieve value for xpath: #{xpath} and file: #{file}. Attempted value is #{node.to_s}"
    return ''
  end
  return node.text
end

def convert_document(xml_file)
  document = Nokogiri::XML.parse(sanitize(File.read(xml_file)))

  # Remove any sensitive content
  document.search('//span').each do |span|
    span_privilege = span.attribute('privilege').to_s
    next if span_privilege.nil? || span_privilege.empty?
    if span_privilege == 'admin' || span_privilege == 'advanced'
      span.children.each do |child|
        span.add_previous_sibling(child)
      end
    end
    span.unlink
  end

  @page_command = document.at_xpath('/command/name').text
  shortdesc = document.at_xpath('/command/shortdesc').text
  privilege = document.at_xpath('/command/privilege').text
  privilege_value = document.at_xpath('/command/privilege_value').text
  vserver = document.at_xpath('/command/vserver').text
  bootlevel = document.at_xpath('/command/bootlevel').text
  bootlevel_value = document.at_xpath('/command/bootlevel_value').text
  hide_ami = document.at_xpath('/command/hide_ami').text
  parent_table = document.at_xpath('/command/parent_table').text
  collapse = document.at_xpath('/command/collapse').text
  action = document.at_xpath('/command/action').text
  description = document.at_xpath('/command/description')   # OPTIONAL
  example = document.xpath('//example')
  parameters = document.xpath('/command/parameters/parameter')
  fields = document.xpath('/command/show-fields/field')

  raise RuntimeError, "Index command name [#{@index_command}] does not match file command name [#{@page_command}] for file [#{xml_file}]. Excluded from output." if(@page_command != @index_command)
  
  begin
    add_entry_with_level(@index_command, @sidebar_entries, 1)
  rescue RuntimeError => e 
    raise RuntimeError, "Duplicate command: #{@index_command}. Skipping file: #{xml_file}"
  end

  adoc = adoc_front_matter(shortdesc)
  adoc << adoc_header()
  adoc << adoc_lead(shortdesc)
  adoc << adoc_availability(hide_ami, vserver, privilege)
  adoc << adoc_description(description)
  adoc << adoc_parameters(parameters)
  adoc << adoc_examples(example)
  adoc << adoc_relative_links()

  # puts adoc if "#{@index_command}" == "cluster join"
  File.open(@output_doc_path+'/'+adoc_file(@index_command), "w") { |afile| afile.write(adoc) }
end

def add_entry_with_level(cmd, list, level)
  if level > @menu_depth
    raise RuntimeError, "Entry already exists" if entry_exists?(list, cmd)
    list.push({ 'title' => cmd, 'url' => permalink(cmd) })
    return
  end

  category_title = category_title_with_level(cmd, level)
  if(category_title.nil?)
    raise RuntimeError, "Entry already exists" if entry_exists?(list, cmd)
    list.push({ 'title' => cmd, 'url' => permalink(cmd) })
  else
    list.push({ 'title' => category_title,'entries' => [] }) unless entry_exists?(list, category_title)
    list.each do |entry|
      if(entry['title'] == category_title)
        add_entry_with_level(cmd, entry['entries'], level+1)
      end 
    end
  end
end

def category_title_with_level(cmd, level)
  cmd_names = cmd.split(' ')
  if cmd_names.length > level
      result = ''
      i = 0
      while i < level
        result = result + cmd_names[i] + ' '
        i = i + 1
      end
      result = result + 'commands'
      return result
  else
      return nil
  end
end

def entry_exists?(entries, title)
  return entries.detect { |e| e['title'] == title }
end

def category_title(cmd)
  cmd_names = cmd.split(' ')
  return (cmd_names.length > 1) ? cmd_names.first+' commands' : nil
end

def sanitize(content)
  sanitized = sanitize_note(content)
  return content
end

def sanitize_note(content)
  content = content.gsub(/\<note\>/,'NOTE: ').gsub(/\<\/note\>/,'')
  return content;
end

def adoc_basename(cmd)
  return cmd.tr(' ','-')
end

def adoc_file(cmd)
  return adoc_basename(cmd) + '.adoc'
end

def permalink(cmd)
  return '/' + adoc_basename(cmd) + '.html'
end

def adoc_front_matter(description)
  keywords = 'cli, command, ' + @index_command
  permalink = permalink(@index_command)
  summary = sanitize_yaml(description)

  front_matter = <<~TEXT
      ---
      sidebar: sidebar
      permalink: #{permalink}
      keywords: #{keywords}
      summary: '#{summary}'
      ---

  TEXT

  return front_matter
end

def sanitize_yaml(text)
  return '' if text.nil?
  # YAML characters: :-{}[]!#|>&%@
  return text.gsub(/((?:\&|\:|\"|\-|\(|\)|\[|\]|\#))/,'\\\\\1').gsub(/\'/,'\'\'')
end

def adoc_header()
  header = <<~TEXT
      = #{@page_command}
      :hardbreaks:
      :linkattrs:
      :imagesdir: ./media/

  TEXT

  return header
end

def adoc_lead(intro)
  lead = <<~TEXT
      [.lead]
      #{intro}

  TEXT

  return lead
end

def adoc_availability(hide_ami, vserver, privilege)
  ami_text = (hide_ami == '1') ? ' hidden':''
  admin_text = (vserver == 'true') ? ' and _Vserver_':''
  availability_text = <<~TEXT
      *Availability:* This#{ami_text} command is available to _cluster_#{admin_text} administrators at the _#{privilege}_ privilege level.

  TEXT

  return availability_text
end

def adoc_description(details)
  return '' if !details
  begin
    details = xml_to_asciidoc(details)
  rescue RuntimeError => e 
    puts "WARN: Unable to parse details. #{e.message}"
    return ''
  end
  description = <<~TEXT
      == Description

      #{details}

  TEXT

  return description
end

def adoc_parameters(parameters)
  return '' if parameters.count == 0
  parameters_text = <<~TEXT
      == Parameters

  TEXT

  parameters.each do |parameter|
    param_name = parameter.at_xpath('name').text
    param_description = parameter.at_xpath('description')
    param_option_char = parameter.at_xpath('option_char').text
    param_type_uiname = parameter.at_xpath('type_uiname').text
    param_privilege = parameter.at_xpath('privilege').text.to_i
    param_bootlevel = parameter.at_xpath('bootlevel').text
    param_list = parameter.at_xpath('list').text
    param_suppress_fieldname = parameter.at_xpath('suppress-fieldname').text
    param_literal_text = parameter.at_xpath('literal-text').text
    param_suppress_dash = parameter.at_xpath('suppress-dash').text
    param_creatable = parameter.at_xpath('creatable').text
    param_modifiable = parameter.at_xpath('modifiable').text
    param_persistent = parameter.at_xpath('persistent').text
    param_isrange = parameter.at_xpath('isrange').text
    param_issizedtext = parameter.at_xpath('issizedtext').text
    param_rangelow = parameter.at_xpath('rangelow').text
    param_rangehigh = parameter.at_xpath('rangehigh').text
    param_is_key = parameter.at_xpath('is-key').text
    param_zapi_element = parameter.at_xpath('zapi-element')
    param_zapi_element_type = parameter.at_xpath('zapi-element-type')
    param_is_hidden = parameter.at_xpath('is-hidden').text
    param_exact = parameter.at_xpath('exact').text
    param_shortdesc = parameter.at_xpath('shortdesc').text
    param_exclusion = parameter.at_xpath('exclusion')
    param_required = parameter.at_xpath('required').text

    next if (param_is_hidden.to_s.strip == 'true' || param_privilege > 1)
    
    #TODO: Determine what to do about exclusion. Exclude if accepted priv is high? 
    exclude_admin = (param_exclusion.attr('admin').strip.to_i > 1) ? true : false
    exclude_advanced = (param_exclusion.attr('advanced').strip.to_i > 1) ? true : false
    # if(exclude_admin || exclude_advanced)
    #   puts "WARN: Parameter #{param_name} for command #{@index_command} is indicated for exclusion."
    # end

    option_dash = (param_suppress_dash.to_s.strip == 'true') ? true : false
    option_char = '-'+param_option_char.to_s.strip unless (param_option_char.empty?)
    option_name = option_dash ? '-'+param_name : param_name

    label_args = []
    label_args.push(option_char) unless (option_char.nil? || option_char.empty? || param_suppress_fieldname.to_s.strip == 'true')
    label_args.push(option_name) unless (option_name.nil? || option_name.empty? || param_suppress_fieldname.to_s.strip == 'true')
    param_value = (!param_type_uiname.to_s.strip.empty?) ? "<#{param_type_uiname}>" : ''

    fields = []
    fields.push(label_args.join(', ')) unless (label_args.empty?)
    fields.push(param_value) unless (param_value.nil? || param_value.empty?)
    field_label = fields.join(' ')
    
    param_required = (param_required.to_s.strip == 'true') ? 'Required. ' : ''
    begin
      parameter_text = <<~TEXT
          `#{field_label}`::
          #{param_required}#{xml_to_asciidoc(param_description)}

      TEXT
      parameters_text << parameter_text
    rescue RuntimeError => e 
      puts "WARN: Unable to parse param #{param_name} for command #{@index_command}. #{e.message}"
      next
    end
  end
  return parameters_text
end

def adoc_examples(examples)
  return '' if examples.count == 0
  examples_text = <<~TEXT
    == Examples

    #{xml_to_asciidoc(examples)}
  TEXT

  return examples_text
end

def adoc_relative_links()
  return '' if @relative_links.empty?
  related_links = <<~TEXT
  == Related Links

  TEXT
  @relative_links.each do |link|
    related_links << text_block('* ' + link)
  end

  related_links << text_block('')
  return related_links
end

##
# Sanitizes and converts standard xml tags to AsciiDoc
#
def xml_to_asciidoc(xml, li_level=0, whitespace=false)
  return '' if !xml
  xml.children.each do |child|
    node_name = child.name.to_s
    if child.blank? || child.comment? || child.processing_instruction?
      child.replace('')
    elsif node_name.nil? || node_name.empty?
      puts "Not a valid xml tag"
    elsif node_name == 'p'
      paragraph = <<~TEXT

        #{xml_to_asciidoc(child,li_level,whitespace)}

      TEXT
      child.replace(paragraph)
    elsif node_name == 'cmdname' || node_name == 'name'
      command = xml_to_asciidoc(child,li_level,whitespace)
      sanitized_command = strip_parameters(command)
      command_adoc = "`#{command}`"
      unless sanitized_command.empty? || current_command?(sanitized_command) || !command_exists?(sanitized_command)
        command_adoc = "link:#{permalink(sanitized_command)}['#{command}']"
        add_relative_link(command_adoc)
      end
      child.replace(command_adoc)
    elsif node_name == 'note'
      # Fix the NOTE if it is inline. 
      previous_node = child.previous
      note = "NOTE: #{xml_to_asciidoc(child,li_level,whitespace)}\n\n"
      note = "\n+\n" + note unless previous_node.nil? || previous_node.text.strip.empty?
      child.replace(note)
    elsif node_name == 'userinput'
      userinput = "`#{xml_to_asciidoc(child,li_level,whitespace)}`"
      child.replace(userinput)
    elsif node_name == 'varname'
      child.replace("`#{xml_to_asciidoc(child,li_level,whitespace)}`")
    elsif node_name == 'br'
      child.replace(" +")
    elsif node_name == 'pre'
      pre = <<~TEXT

        ----
        #{child.inner_html.to_s}
        ----

      TEXT
      child.replace(pre)
    elsif node_name == 'screen'
      # Left align screen contents by left-most line
      screen_text = xml_to_asciidoc(child,li_level,true).gsub(/\t/,'  ')
      screen_lines = screen_text.split("\n")
      spaces = nil
      screen_lines.collect! { |line|
        next if line.strip.empty?
        spaces = line[/\A */].size if spaces.nil?
        line = line[spaces, line.length]
      }
      screen_text = screen_lines.join("\n")
      
      screen = <<~TEXT

        ----
        #{screen_text}
        ----

      TEXT
      child.replace(screen)
    elsif node_name == 'ul' || node_name == 'ol'
      li_level = li_level + 1 if (child.parent.name == 'li')
      space = '  ' * li_level
      entries = text_block('')
      entries << text_block('')
      child.children.each do |li|
        next if li.blank? || li.comment?
        adoc_symbol = (node_name == 'ul') ? '* ' : '. '
        entries << text_block(space + adoc_symbol + xml_to_asciidoc(li, li_level, whitespace))
      end
      entries << text_block('')
      child.replace(entries)
    elsif node_name == 'a'
      link = "link:#{child.attr('href')}['#{child.inner_html.to_s}']"
      child.replace(link)
    elsif node_name == 'vendor-text'
      child.replace('NetApp')
    elsif node_name == 'draft-comment'
      child.replace('')   # Typically for BURT
    elsif node_name == 'text'
      content = child.text
      content = content.gsub(/^\n\s+/, '')
      content = content.gsub(/[\n\t]+/, '') unless whitespace
      content = content.gsub(/\s+/, ' ') unless whitespace
      child.replace(content)
      next
    else
      raise RuntimeError, "Undefined xml tag [#{node_name}] for command [#{@index_command}]"
    end
  end

  return xml.text
end

def text_block(text)
  block = <<~TEXT
    #{text}
  TEXT
  return block
end

def current_command?(command)
  return (command == @page_command || command == @index_command) ? true : false 
end

def add_relative_link(link)
  @relative_links.push(link) unless @relative_links.include?(link)
end

##
# Remove all parameters from a command. 
# Returns an empty string if command is a parameter
#
def strip_parameters(command)
  command = command.gsub(/\s+\-.*/,'').gsub(/^\-.*/,'').strip
  puts "WARN: Command [#{command}] referenced in man page [#{@index_command}] is not included" unless command.empty? || command_exists?(command) || !ntap_command?(command)
  return command 
end

def command_exists?(command)
  return @commands.include?(command)
end

def ntap_command?(command)
  return @commands.any? { |cmd| command.include?(cmd) }
end

##
# Find a key-value pair in sidebar hash and replace structure
# Supports project.yml or sidebar.yml
# Returns boolean
#
def find_and_replace(object, key, value, replace, parent=nil, position=nil)
  if !object[key].nil? && object[key] == value
    replace_id(object, key, replace, parent, position)
    return true
  end

  return false if object['entries'].nil?
  object['entries'].each_with_index do |entry,position|
    result = find_and_replace(entry, key, value, replace, object, position)
    return true if result
  end

  return false
end

def replace_id(h, key, replace, parent, position)
  if replace.is_a?(Hash)
    a = {}
    keys = h.keys
    idx = keys.index(key)
    keys[idx..-1].each do |k|
        a.store(k, h.delete(k))
    end
    h.merge!(replace)
    h.merge!(a)
    h.delete(key)
  else
    parent['entries'].slice!(position)
    parent['entries'].insert(position, *replace)
  end
end

def xml_path(absolute_html_path)
  return File.join(File.dirname(absolute_html_path), File.basename(absolute_html_path, '.*')) + '.xml'
end

def output_xml_path(relative_html_path)
  absolute_html_path = File.join(@output_doc_path, Pathname.new(relative_html_path).cleanpath.to_s)
  return xml_path(absolute_html_path)
end

def input_xml_path(relative_html_path)
  absolute_html_path = File.join(@input_dir, Pathname.new(relative_html_path).cleanpath.to_s)
  return xml_path(absolute_html_path)
end

abort('No CLI_INPUT argument provided') if (ENV['CLI_INPUT'].nil? || ENV['CLI_INPUT'].empty?) 
abort('No CLI_INPUT_TEMPLATE_FILE argument provided') if (ENV['CLI_INPUT_TEMPLATE_FILE'].nil? || ENV['CLI_INPUT_TEMPLATE_FILE'].empty?) 
abort('No CLI_OUTPUT argument provided') if (ENV['CLI_OUTPUT'].nil? || ENV['CLI_OUTPUT'].empty?) 

input_doc_path = Pathname.new(ENV['CLI_INPUT']).cleanpath.to_s
@output_doc_path = Pathname.new(ENV['CLI_OUTPUT']).cleanpath.to_s

@input_dir = Pathname.new(input_doc_path).cleanpath.to_s
input_template_file = Pathname.new(ENV['CLI_INPUT_TEMPLATE_FILE']).cleanpath
output_name = input_template_file.basename

# Read the file before deleting the output folder in case it is in the same directory
template_file = nil
template_file = YAML.load_file(input_template_file.to_s) if(File.file?(input_template_file.to_s))

@sidebar_entries = []

# Clean up folder
FileUtils.rm_rf(@output_doc_path) if EXTRACT_XML
FileUtils.mkdir_p(@output_doc_path) if EXTRACT_XML

@commands = []
traverse_files
write_sidebar(template_file, output_name) unless EXTRACT_XML
extract('./man_index.xml') if EXTRACT_XML