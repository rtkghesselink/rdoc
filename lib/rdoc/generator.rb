require 'cgi'
require 'rdoc'
require 'rdoc/options'
require 'rdoc/markup/to_html_crossref'
require 'rdoc/template'
require 'rdoc/cache'

module RDoc::Generator

  ##
  # Name of sub-directory that holds file descriptions

  FILE_DIR  = "files"

  ##
  # Name of sub-directory that holds class descriptions

  CLASS_DIR = "classes"

  ##
  # Name of the RDoc CSS file

  CSS_NAME  = "rdoc-style.css"

  ##
  # A hash of all items that can be cross-referenced.
  #
  # This is used when we output required and included names.  If the names
  # appear in this hash we can generate an html cross reference to the
  # appropriate description.
  #
  # We also use this when parsing comment blocks.  Any decorated words
  # matching an entry in this list are hyperlinked.

  class AllReferences

    ##
    # Access +name+ in the reference store

    def self.[](name)
      @@refs[name]
    end

    ##
    # Add +name+ that references +html_class+

    def self.add(name, html_class)
      @@refs[name] = html_class
    end

    ##
    # List of all known names

    def self.keys
      @@refs.keys
    end

    ##
    # Empties the reference store

    def self.reset
      @@refs = {}
    end

    reset

  end

  ##
  # Handle common markup tasks for the various Context subclasses

  module MarkUp

    ##
    # Convert a string in markup format into HTML.

    def markup(str, remove_para = false)
      return '' unless str

      # Convert leading comment markers to spaces, but only if all non-blank
      # lines have them
      if str =~ /^(?>\s*)[^\#]/ then
        content = str
      else
        content = str.gsub(/^\s*(#+)/) { $1.tr '#', ' ' }
      end

      res = formatter.convert content

      if remove_para then
        res.sub!(/^<p>/, '')
        res.sub!(/<\/p>$/, '')
      end

      res
    end

    ##
    # Qualify a stylesheet URL; if if +css_name+ does not begin with '/' or
    # 'http[s]://', prepend a prefix relative to +path+. Otherwise, return it
    # unmodified.

    def style_url(path, css_name=nil)
#      $stderr.puts "style_url( #{path.inspect}, #{css_name.inspect} )"
      css_name ||= CSS_NAME
      if %r{^(https?:/)?/} =~ css_name
        css_name
      else
        RDoc::Markup::ToHtml.gen_relative_url path, css_name
      end
    end

    ##
    # Build a webcvs URL with the given 'url' argument. URLs with a '%s' in them
    # get the file's path sprintfed into them; otherwise they're just catenated
    # together.

    def cvs_url(url, full_path)
      if /%s/ =~ url
        return sprintf( url, full_path )
      else
        return url + full_path
      end
    end

  end

  ##
  # A Context is built by the parser to represent a container: contexts hold
  # classes, modules, methods, require lists and include lists.  ClassModule
  # and TopLevel are the context objects we process here

  class Context

    include MarkUp

    attr_reader :context

    ##
    # Generate:
    #
    # * a list of RDoc::Generator::File objects for each TopLevel object
    # * a list of RDoc::Generator::Class objects for each first level class or
    #   module in the TopLevel objects
    # * a complete list of all hyperlinkable terms (file, class, module, and
    #   method names)

    def self.build_indices(toplevels, options, template_cache = nil)
      files = []
      classes = []
      template_cache ||= RDoc::Cache.instance

      file_dir = if defined? options.generator::FILE_DIR then
                   options.generator::FILE_DIR
                 else
                   RDoc::Generator::FILE_DIR
                 end

      toplevels.each do |toplevel|
        files << RDoc::Generator::File.new(template_cache, toplevel, options,
                                           file_dir)
      end

      class_dir = if defined? options.generator::CLASS_DIR then
                   options.generator::CLASS_DIR
                 else
                   RDoc::Generator::CLASS_DIR
                 end

      RDoc::TopLevel.all_classes_and_modules.each do |cls|
        build_class_list(template_cache, classes, options, cls, files[0], 
                         class_dir)
      end

      return files, classes
    end

    def self.build_class_list(template_cache, classes, options, from, html_file, class_dir)
      classes << RDoc::Generator::Class.new(template_cache, from, html_file, class_dir, options)

      from.each_classmodule do |mod|
        build_class_list(template_cache, classes, options, mod, html_file, class_dir)
      end
    end

    def initialize(context, options)
      @context = context
      @options = options

      # HACK ugly
      @template = options.template_class
    end

    def formatter
      @formatter ||= @options.formatter ||
        RDoc::Markup::ToHtmlCrossref.new(path, self, @options.show_hash)
    end

    ##
    # convenience method to build a hyperlink

    def href(link, cls, name)
      %{<a href="#{link}" class="#{cls}">#{name}</a>} #"
    end

    ##
    # Returns a reference to outselves to be used as an href= the form depends
    # on whether we're all in one file or in multiple files

    def as_href(from_path)
      if @options.all_one_file
        "#" + path
      else
        RDoc::Markup::ToHtml.gen_relative_url from_path, path
      end
    end

    ##
    # Create a list of Method objects for each method in the corresponding
    # context object. If the @options.show_all variable is set (corresponding
    # to the <tt>--all</tt> option, we include all methods, otherwise just the
    # public ones.

    def collect_methods
      list = @context.method_list

      unless @options.show_all then
        list = list.select do |m|
          m.visibility == :public or
            m.visibility == :protected or
            m.force_documentation
        end
      end

      @methods = list.collect do |m|
        RDoc::Generator::Method.new m, self, @options
      end
    end

    ##
    # Build a summary list of all the methods in this context

    def build_method_summary_list(path_prefix = "")
      collect_methods unless @methods

      @methods.sort.map do |meth|
        {
          :name => CGI.escapeHTML(meth.name),
          :aref => "##{meth.aref}"
        }
      end
    end

    ##
    # Build a list of aliases for which we couldn't find a
    # corresponding method

    def build_alias_summary_list(section)
      @context.aliases.map do |al|
        next unless al.section == section

        res = {
          :old_name => al.old_name,
          :new_name => al.new_name,
        }

        if al.comment and not al.comment.empty? then
          res[:desc] = markup al.comment, true
        end

        res
      end.compact
    end

    ##
    # Build a list of constants

    def build_constants_summary_list(section)
      @context.constants.map do |co|
        next unless co.section == section

        res = {
          :name  => co.name,
          :value => CGI.escapeHTML(co.value)
        }

        if co.comment and not co.comment.empty? then
          res[:desc] = markup co.comment, true
        end

        res
      end.compact
    end

    def build_requires_list(context)
      potentially_referenced_list(context.requires) {|fn| [fn + ".rb"] }
    end

    def build_include_list(context)
      potentially_referenced_list(context.includes)
    end

    ##
    # Build a list from an array of Context items. Look up each in the
    # AllReferences hash: if we find a corresponding entry, we generate a
    # hyperlink to it, otherwise just output the name.  However, some names
    # potentially need massaging. For example, you may require a Ruby file
    # without the .rb extension, but the file names we know about may have it.
    # To deal with this, we pass in a block which performs the massaging,
    # returning an array of alternative names to match

    def potentially_referenced_list(array)
      res = []
      array.each do |i|
        ref = AllReferences[i.name]
#         if !ref
#           container = @context.parent
#           while !ref && container
#             name = container.name + "::" + i.name
#             ref = AllReferences[name]
#             container = container.parent
#           end
#         end

        ref = @context.find_symbol(i.name)
        ref = ref.viewer if ref

        if !ref && block_given?
          possibles = yield(i.name)
          while !ref and !possibles.empty?
            ref = AllReferences[possibles.shift]
          end
        end
        h_name = CGI.escapeHTML(i.name)
        if ref and ref.document_self
          path = url(ref.path)
          res << { :name => h_name, :aref => path }
        else
          res << { :name => h_name }
        end
      end
      res
    end

    ##
    # Build an array of arrays of method details. The outer array has up
    # to six entries, public, private, and protected for both class
    # methods, the other for instance methods. The inner arrays contain
    # a hash for each method

    def build_method_detail_list(section)
      outer = []

      methods = @methods.sort.select do |m|
        m.document_self and m.section == section
      end

      for singleton in [true, false]
        for vis in [ :public, :protected, :private ]
          res = []
          methods.each do |m|
            next unless m.visibility == vis and m.singleton == singleton

            row = {}

            if m.call_seq then
              row[:callseq] = m.call_seq.gsub(/->/, '&rarr;')
            else
              row[:name]        = CGI.escapeHTML(m.name)
              row[:params]      = m.params
            end

            desc = m.description.strip
            row[:m_desc]      = desc unless desc.empty?
            row[:aref]        = m.aref
            row[:visibility]  = m.visibility.to_s

            alias_names = []

            m.aliases.each do |other|
              if other.viewer then # won't be if the alias is private
                alias_names << {
                  :name => other.name,
                  :aref  => other.viewer.as_href(path)
                }
              end
            end

            row[:aka] = alias_names unless alias_names.empty?

            if @options.inline_source then
              code = m.source_code
              row[:sourcecode] = code if code
            else
              code = m.src_url
              if code then
                row[:codeurl] = code
                row[:imgurl]  = m.img_url
              end
            end

            res << row
          end

          if res.size > 0 then
            outer << {
              :type     => vis.to_s.capitalize,
              :category => singleton ? "Class" : "Instance",
              :methods  => res
            }
          end
        end
      end

      outer
    end

    ##
    # Build the structured list of classes and modules contained
    # in this context.

    def build_class_list(level, from, section, infile=nil)
      prefix = '&nbsp;&nbsp;::' * level;
      res = ''

      from.modules.sort.each do |mod|
        next unless mod.section == section
        next if infile && !mod.defined_in?(infile)
        if mod.document_self
          res <<
            prefix <<
            'Module ' <<
            href(url(mod.viewer.path), 'link', mod.full_name) <<
            "<br />\n" <<
            build_class_list(level + 1, mod, section, infile)
        end
      end

      from.classes.sort.each do |cls|
        next unless cls.section == section
        next if infile and not cls.defined_in?(infile)

        if cls.document_self
          res <<
            prefix <<
            'Class ' <<
            href(url(cls.viewer.path), 'link', cls.full_name) <<
            "<br />\n" <<
            build_class_list(level + 1, cls, section, infile)
        end
      end

      res
    end

    def url(target)
      RDoc::Markup::ToHtml.gen_relative_url path, target
    end

    def aref_to(target)
      if @options.all_one_file
        "#" + target
      else
        url(target)
      end
    end

    def document_self
      @context.document_self
    end

    def diagram_reference(diagram)
      res = diagram.gsub(/((?:src|href)=")(.*?)"/) {
        $1 + url($2) + '"'
      }
      res
    end

    ##
    # Find a symbol in ourselves or our parent

    def find_symbol(symbol, method=nil)
      res = @context.find_symbol(symbol, method)
      if res
        res = res.viewer
      end
      res
    end

    ##
    # create table of contents if we contain sections

    def add_table_of_sections
      toc = []
      @context.sections.each do |section|
        if section.title then
          toc << {
            :secname => section.title,
            :href    => section.sequence
          }
        end
      end

      @values[:toc] = toc unless toc.empty?
    end

  end

  ##
  # Wraps a ClassModule CodeObject for use by a Generator

  class Class < Context

    attr_reader :methods
    attr_reader :path
    attr_reader :values

    def initialize(template_cache, context, html_file, prefix, options)
      super context, options

      @template_cache = template_cache
      @html_file = html_file
      @html_class = self
      @is_module = context.module?
      @values    = {}

      context.viewer = self

      if options.all_one_file
        @path = context.full_name
      else
        @path = http_url(context.full_name, prefix)
      end

      collect_methods

      AllReferences.add(name, self)
    end

    ##
    # Returns the relative file name to store this class in, which is also its
    # url

    def http_url(full_name, prefix)
      path = full_name.dup

      path.gsub!(/<<\s*(\w*)/, 'from-\1') if path['<<']

      path = [prefix] + path.split('::')

      ::File.join(*path.compact) + ".html"
    end

    ##
    # Name of this class

    def name
      @context.full_name
    end

    ##
    # Name of this class' parent

    def parent_name
      @context.parent.full_name
    end

    def index_name
      name
    end

    ##
    # Writes this class to +f+

    def write_on(f, file_list, class_list, method_list, overrides = {})
      value_hash

      @values[:file_list] = file_list
      @values[:class_list] = class_list
      @values[:method_list] = method_list

      @values.update overrides

      template_page = @template_cache.cache(@template) do
        RDoc::TemplatePage.new(@template::BODY,
                               @template::CLASS_PAGE,
                               @template::METHOD_LIST)
      end

      template_page.write_html_on(f, @values)
    end

    ##
    # A Hash representation of this class used for filling in templates

    def value_hash
      class_attribute_values
      add_table_of_sections

      @values[:charset] = @options.charset
      @values[:style_url] = style_url(path, @options.css)

      d = markup(@context.comment)
      @values[:description] = d unless d.empty?

      ml = build_method_summary_list @path
      @values[:methods] = ml unless ml.empty?

      il = build_include_list @context
      @values[:includes] = il unless il.empty?

      @values[:sections] = @context.sections.map do |section|
        secdata = {
          :sectitle    => section.title,
          :secsequence => section.sequence,
          :seccomment  => markup(section.comment),
        }

        al = build_alias_summary_list section
        secdata[:aliases] = al unless al.empty?

        co = build_constants_summary_list section
        secdata[:constants] = co unless co.empty?

        al = build_attribute_list section
        secdata[:attributes] = al unless al.empty?

        cl = build_class_list 0, @context, section
        secdata[:classlist] = cl unless cl.empty?

        mdl = build_method_detail_list section
        secdata[:method_list] = mdl unless mdl.empty?

        secdata
      end

      @values
    end

    ##
    # Hash representation of this class' attributes that belongs to +section+

    def build_attribute_list(section)
      @context.attributes.sort.map do |att|
        next unless att.section == section

        if att.visibility == :public or att.visibility == :protected or
           @options.show_all then

          entry = {
            :name   => CGI.escapeHTML(att.name),
            :rw     => att.rw,
            :a_desc => markup(att.comment, true)
          }

          unless att.visibility == :public or att.visibility == :protected then
            entry[:rw] << "-"
          end

          entry
        end
      end.compact
    end

    def class_attribute_values
      h_name = CGI.escapeHTML(name)

      @values[:href]      = @path
      @values[:classmod]  = @is_module ? "Module" : "Class"
      @values[:title]     = "#{@values['classmod']}: #{h_name} [#{@options.title}]"

      c = @context
      c = c.parent while c and not c.diagram

      if c and c.diagram then
        @values[:diagram] = diagram_reference(c.diagram)
      end

      @values[:full_name] = h_name

      if not @context.module? and @context.superclass then
        parent_class = @context.superclass
        @values[:parent] = CGI.escapeHTML(parent_class)

        if parent_name
          lookup = parent_name + "::" + parent_class
        else
          lookup = parent_class
        end

        parent_url = AllReferences[lookup] || AllReferences[parent_class]

        if parent_url and parent_url.document_self
          @values[:par_url] = aref_to(parent_url.path)
        end
      end

      files = []
      @context.in_files.each do |f|
        res = {}
        full_path = CGI.escapeHTML(f.file_absolute_name)

        res[:full_path]     = full_path
        res[:full_path_url] = aref_to(f.viewer.path) if f.document_self

        if @options.webcvs
          res[:cvsurl] = cvs_url( @options.webcvs, full_path )
        end

        files << res
      end

      @values[:infiles] = files
    end

    ##
    # Classes are ordered by name

    def <=>(other)
      self.name <=> other.name
    end

    def inspect # :nodoc:
      "#<#{self.class} name: #{name} path: #{@path}>"
    end

    def pretty_print(q) # :nodoc:
      q.group 1, "#<#{self.class} ", '>' do
        q.text 'name: '
        q.pp name
        q.text ','
        q.breakable

        q.text 'path: '
        q.pp @path
        q.text ','
        q.breakable

        q.text 'values: '
        q.pp @values
        q.text ','
        q.breakable

        q.text 'methods: '
        q.pp @methods
      end
    end

  end

  ##
  # Wraps a TopLevel CodeObject for use by a Generator

  class File < Context

    ##
    # Path this file was found at

    attr_reader :path

    ##
    # Name of the file

    attr_reader :name

    attr_reader :values

    def initialize(template_cache, context, options, file_dir)
      super context, options

      @values = {}
      @template_cache = template_cache

      if options.all_one_file
        @path = filename_to_label
      else
        @path = http_url(file_dir)
      end

      @name = @context.file_relative_name

      collect_methods
      AllReferences.add(name, self)
      context.viewer = self
    end

    def http_url(file_dir)
      path = [file_dir, "#{@context.file_relative_name.tr '.', '_'}.html"]

      ::File.join path.compact
    end

    def filename_to_label
      @context.file_relative_name.gsub(/%|\/|\?|\#/) do
        ('%%%x' % $&[0]).unpack('C')
      end
    end

    def index_name
      name
    end

    ##
    # A file doesn't have a parent

    def parent_name
      nil
    end

    ##
    # Hash representation of this file

    def value_hash
      file_attribute_values
      add_table_of_sections

      @values[:charset]   = @options.charset
      @values[:href]      = path
      @values[:parser]    = @context.parser
      @values[:style_url] = style_url(path, @options.css)

      if @context.comment
        d = markup(@context.comment)
        @values[:description] = d if d.size > 0
      end

      ml = build_method_summary_list
      @values[:methods] = ml unless ml.empty?

      il = build_include_list(@context)
      @values[:includes] = il unless il.empty?

      rl = build_requires_list(@context)
      @values[:requires] = rl unless rl.empty?

      file_context = @context unless @options.promiscuous

      @values[:sections] = @context.sections.map do |section|
        secdata = {
          :sectitle => section.title,
          :secsequence => section.sequence,
          :seccomment => markup(section.comment)
        }

        cl = build_class_list(0, @context, section, file_context)
        secdata[:classlist] = cl unless cl.empty?

        mdl = build_method_detail_list(section)
        secdata[:method_list] = mdl unless mdl.empty?

        al = build_alias_summary_list(section)
        secdata[:aliases] = al unless al.empty?

        co = build_constants_summary_list(section)
        secdata[:constants] = co unless co.empty?

        secdata
      end

      @values
    end

    ##
    # Writes this file to +f+

    def write_on(f, file_list, class_list, method_list, overrides = {})
      value_hash

      @values[:file_list] = file_list
      @values[:class_list] = class_list
      @values[:method_list] = method_list

      @values.update overrides

      template_page = @template_cache.cache(@template) do
        RDoc::TemplatePage.new(@template::BODY,
                               @template::FILE_PAGE,
                               @template::METHOD_LIST)
      end
      template_page.write_html_on(f, @values)
    end

    def file_attribute_values
      full_path = @context.file_absolute_name
      short_name = ::File.basename full_path

      @values[:title] = CGI.escapeHTML("File: #{short_name} [#{@options.title}]")

      if @context.diagram then
        @values[:diagram] = diagram_reference(@context.diagram)
      end

      @values[:short_name]   = CGI.escapeHTML(short_name)
      @values[:full_path]    = CGI.escapeHTML(full_path)
      @values[:dtm_modified] = @context.file_stat.mtime.to_s

      if @options.webcvs then
        @values[:cvsurl] = cvs_url @options.webcvs, @values[:full_path]
      end
    end

    ##
    # Files are ordered by name

    def <=>(other)
      self.name <=> other.name
    end

    def inspect # :nodoc:
      "#<#{self.class} name: #{@name} path: #{@path}>"
    end

    def pretty_print(q) # :nodoc:
      q.group 1, "#<#{self.class} ", '>' do
        q.text 'name: '
        q.pp @name
        q.text ','
        q.breakable

        q.text 'path: '
        q.pp @path
        q.text ','
        q.breakable

        q.text 'values: '
        q.pp @values
      end
    end

  end

  ##
  # Wraps an AnyMethod CodeObject for use by a Generator

  class Method

    include MarkUp

    ##
    # CodeObject this method points to

    attr_reader :context
    attr_reader :src_url
    attr_reader :img_url
    attr_reader :source_code

    ##
    # All methods known by the generator

    def self.all_methods
      @@all_methods
    end

    ##
    # Resets the method cache

    def self.reset
      @@all_methods = []
      @@seq = "M000000"
    end

    # Initialize the class variables.
    self.reset

    def initialize(context, html_class, options)
      # TODO: rethink the class hierarchy here...
      @context    = context
      @html_class = html_class
      @options    = options

      @@seq       = @@seq.succ
      @seq        = @@seq

      # HACK ugly
      @template = options.template_class

      @@all_methods << self

      context.viewer = self

      if ts = @context.token_stream then
        @source_code = markup_code ts

        unless @options.inline_source then
          @src_url = create_source_code_file @source_code
          @img_url = RDoc::Markup::ToHtml.gen_relative_url path, 'source.png'
        end
      end

      AllReferences.add name, self
    end

    ##
    # Returns a reference to outselves to be used as an href= the form depends
    # on whether we're all in one file or in multiple files

    def as_href(from_path)
      if @options.all_one_file
        "#" + path
      else
        RDoc::Markup::ToHtml.gen_relative_url from_path, path
      end
    end

    def formatter
      @formatter ||= @options.formatter ||
        RDoc::Markup::ToHtmlCrossref.new(path, self, @options.show_hash)
    end

    def inspect # :nodoc:
      alias_for = if @context.is_alias_for then
                    " (alias_for #{@context.is_alias_for})"
                  else
                    nil
                  end

      "#<%s:0x%x %s%s%s (%s)%s>" % [
        self.class, object_id,
        @context.parent.name,
        @context.singleton ? '::' : '#',
        name,
        @context.visibility,
        alias_for
      ]
    end

    ##
    # Method name

    def name
      @context.name
    end

    ##
    # Section this method belongs to

    def section
      @context.section
    end

    def index_name
      "#{@context.name} (#{@html_class.name})"
    end

    def parent_name
      if @context.parent.parent
        @context.parent.parent.full_name
      else
        nil
      end
    end

    def aref
      @seq
    end

    def path
      if @options.all_one_file
        aref
      else
        @html_class.path + "#" + aref
      end
    end

    def description
      markup(@context.comment)
    end

    ##
    # public, protected, private

    def visibility
      @context.visibility
    end

    ##
    # Is this method a singleton method?

    def singleton
      @context.singleton
    end

    def call_seq
      cs = @context.call_seq
      if cs
        cs.gsub(/\n/, "<br />\n")
      else
        nil
      end
    end

    def params
      # params coming from a call-seq in 'C' will start with the
      # method name
      params = @context.params
      if params !~ /^\w/
        params = @context.params.gsub(/\s*\#.*/, '')
        params = params.tr("\n", " ").squeeze(" ")
        params = "(" + params + ")" unless params[0] == ?(

        if (block = @context.block_params)
         # If this method has explicit block parameters, remove any
         # explicit &block

         params.sub!(/,?\s*&\w+/, '')

          block.gsub!(/\s*\#.*/, '')
          block = block.tr("\n", " ").squeeze(" ")
          if block[0] == ?(
            block.sub!(/^\(/, '').sub!(/\)/, '')
          end
          params << " {|#{block.strip}| ...}"
        end
      end
      CGI.escapeHTML(params)
    end

    def create_source_code_file(code_body)
      meth_path = @html_class.path.sub(/\.html$/, '.src')
      FileUtils.mkdir_p(meth_path)
      file_path = ::File.join meth_path, "#{@seq}.html"

      template = RDoc::TemplatePage.new(@template::SRC_PAGE)

      open file_path, 'w' do |f|
        values = {
          :title     => CGI.escapeHTML(index_name),
          :code      => code_body,
          :style_url => style_url(file_path, @options.css),
          :charset   => @options.charset
        }
        template.write_html_on(f, values)
      end

      RDoc::Markup::ToHtml.gen_relative_url path, file_path
    end

    ##
    # Methods are sorted by name

    def <=>(other)
      @context <=> other.context
    end

    ##
    # Given a sequence of source tokens, mark up the source code to make it
    # look purty.

    def markup_code(tokens)
      src = ""
      tokens.each do |t|
        next unless t
#        style = STYLE_MAP[t.class]
        style = case t
                when RDoc::RubyToken::TkCONSTANT then "ruby-constant"
                when RDoc::RubyToken::TkKW       then "ruby-keyword kw"
                when RDoc::RubyToken::TkIVAR     then "ruby-ivar"
                when RDoc::RubyToken::TkOp       then "ruby-operator"
                when RDoc::RubyToken::TkId       then "ruby-identifier"
                when RDoc::RubyToken::TkNode     then "ruby-node"
                when RDoc::RubyToken::TkCOMMENT  then "ruby-comment cmt"
                when RDoc::RubyToken::TkREGEXP   then "ruby-regexp re"
                when RDoc::RubyToken::TkSTRING   then "ruby-value str"
                when RDoc::RubyToken::TkVal      then "ruby-value"
                else
                  nil
                end

        text = CGI.escapeHTML(t.text)

        if style
          src << "<span class=\"#{style}\">#{text}</span>"
        else
          src << text
        end
      end

      add_line_numbers(src) if @options.include_line_numbers
      src
    end

    ##
    # We rely on the fact that the first line of a source code listing has
    #    # File xxxxx, line dddd

    def add_line_numbers(src)
      if src =~ /\A.*, line (\d+)/ then
        first = $1.to_i - 1
        last  = first + src.count("\n")
        size = last.to_s.length

        line = first
        src.gsub!(/^/) do
          res = if line == first then
                  " " * (size + 2)
                else
                  "%#{size}d: " % line
                end

          line += 1
          res
        end
      end
    end

    ##
    # Should this method be included in generated documentation?

    def document_self
      @context.document_self
    end

    ##
    # Array of other names for this method

    def aliases
      @context.aliases
    end

    def find_symbol(symbol, method=nil)
      res = @context.parent.find_symbol(symbol, method)
      if res
        res = res.viewer
      end
      res
    end

  end

end

