# frozen_string_literal: true

require "set"
require "fileutils"
require "nokogiri"
require "securerandom"
require "digest"

require "active_support/core_ext/string/output_safety"
require "active_support/core_ext/object/blank"
require "action_controller"
require "action_view"

require "rails_guides/markdown"
require "rails_guides/helpers"
require "rails_guides/epub"

module RailsGuides
  class Generator
    GUIDES_RE = /\.(?:erb|md)\z/

    def initialize(edge:, version:, all:, only:, epub:, language:, direction: nil, lint:)
      @edge      = edge
      @version   = version
      @all       = all
      @only      = only
      @epub      = epub
      @language  = language
      @direction = direction || "ltr"
      @lint = lint
      @warnings = []

      if @epub
        register_special_mime_types
      end

      initialize_dirs
      create_output_dir_if_needed if !dry_run?
      initialize_markdown_renderer
    end

    def generate
      if !dry_run?
        # this needs to run before generate guides in order to get the hash values for the CSS files
        process_scss
        copy_assets
      end

      generate_guides

      if @lint && @warnings.any?
        puts "#{@warnings.join("\n")}"
        exit 1
      end

      if !dry_run?
        generate_epub if @epub
      end
    end

    private
      def dry_run?
        [@lint].any?
      end

      def register_special_mime_types
        Mime::Type.register_alias("application/xml", :opf, %w(opf))
        Mime::Type.register_alias("application/xml", :ncx, %w(ncx))
      end

      def generate_epub
        Epub.generate(@output_dir, epub_filename)
        puts "Epub generated at: output/epub/#{epub_filename}"
      end

      def epub_filename
        epub_filename = +"ruby_on_rails_guides_#{@version || @edge[0, 7]}"
        epub_filename << ".#{@language}" if @language
        epub_filename << ".epub"
      end

      def initialize_dirs
        @guides_dir = File.expand_path("..", __dir__)

        @source_dir  = "#{@guides_dir}/source"
        @source_dir += "/#{@language}" if @language

        @output_dir  = "#{@guides_dir}/output"
        @output_dir += "/epub/OEBPS"       if @epub
        @output_dir += "/#{@language}" if @language
      end

      def create_output_dir_if_needed
        FileUtils.mkdir_p(@output_dir)
      end

      def initialize_markdown_renderer
        Markdown::Renderer.edge    = @edge
        Markdown::Renderer.version = @version
      end

      def generate_guides
        guides_to_generate.each do |guide|
          output_file = output_file_for(guide)
          generate_guide(guide, output_file) if generate?(guide, output_file)
        end
      end

      def guides_to_generate
        guides = Dir.entries(@source_dir).grep(GUIDES_RE)

        if @epub
          Dir.entries("#{@source_dir}/epub").grep(GUIDES_RE).map do |entry|
            guides << "epub/#{entry}"
          end
        end

        @only ? select_only(guides) : guides
      end

      def select_only(guides)
        prefixes = @only.split(",").map(&:strip)
        guides.select do |guide|
          guide.start_with?("epub", *prefixes)
        end
      end

      def process_scss
        # Initialize the hash to store the css files with digest
        @css_files_with_digest = {}

        # The sass source and their corresponding finished css names
        scss_source =[
          ["style.scss", "style.css"],
          ["highlight.scss", "highlight.css"],
          ["print.scss", "print.css"]
        ]

        # Process each file, add a cache, and move the file into place. 
        scss_source.each do |source, output|
          source_file = "#{@guides_dir}/assets/stylesrc/#{source}"
          output_file = "#{@output_dir}/stylesheets/#{output}"

          system "bundle exec dartsass #{source_file}:#{output_file}"

          if File.exist?(output_file)
            hash = Digest::MD5.file(output_file).hexdigest
            new_output_filename = output.sub(/\.css\z/, "-#{hash}.css")
            new_output_path = "#{@output_dir}/stylesheets/#{new_output_filename}"
            FileUtils.mv(output_file, new_output_path)
            @css_files_with_digest[output] = new_output_filename
          end
        end
      end

      # Copy all assets except the stylesrc directory with md5 hashes as well
      def copy_assets
        # Reject the source SCSS files from being included in the copy
        source_directories = Dir.glob("#{@guides_dir}/assets/*").reject { |name| name.include?("stylesrc") }
        source_files = [] # NEED TO FIGURE OUT
      
        # MD5 the files, update the name, and copy them to the output directory
        source_files.each do |file|
          if File.file?(file)
            hash = Digest::MD5.file(file).hexdigest
            ext = File.extname(file)
            basename = File.basename(file, ext)
            new_filename = "#{basename}-#{hash}#{ext}"
            
            FileUtils.cp(file, "#{@output_dir}/#{new_filename}")
          else
            FileUtils.cp_r(file, @output_dir)
          end
        end
      end

      def css_file_with_digest(original_filename)
        @css_files_with_digest[original_filename] || original_filename
      end

      def output_file_for(guide)
        if guide.end_with?(".md")
          guide.sub(/md\z/, "html")
        else
          guide.delete_suffix(".erb")
        end
      end

      def output_path_for(output_file)
        File.join(@output_dir, File.basename(output_file))
      end

      def generate?(source_file, output_file)
        fin  = File.join(@source_dir, source_file)
        fout = output_path_for(output_file)
        @all || !File.exist?(fout) || File.mtime(fout) < File.mtime(fin)
      end

      def generate_guide(guide, output_file)
        output_path = output_path_for(output_file)
        puts "Generating #{guide} as #{output_file}"
        layout = @epub ? "epub/layout" : "layout"

        view = ActionView::Base.with_empty_template_cache.with_view_paths(
          [@source_dir],
          edge:                  @edge,
          version:               @version,
          epub:                  "epub/#{epub_filename}",
          language:              @language,
          direction:             @direction,
          uuid:                  SecureRandom.uuid,
          css_files_with_digest: @css_files_with_digest
        )
        view.extend(Helpers)

        if guide =~ /\.(\w+)\.erb$/
          return if %w[_license _welcome layout].include?($`)

          # Generate the special pages like the home.
          # Passing a template handler in the template name is deprecated. So pass the file name without the extension.
          result = view.render(layout: layout, formats: [$1.to_sym], template: $`)
        else
          body = File.read("#{@source_dir}/#{guide}")
          result = RailsGuides::Markdown.new(
            view:    view,
            layout:  layout,
            edge:    @edge,
            version: @version,
            epub:    @epub
          ).render(body)

          broken = warn_about_broken_links(result)
          if broken.any?
            @warnings << "[WARN] BROKEN LINK(s): #{guide}: #{broken.join(", ")}"
          end
        end

        File.open(output_path, "w") do |f|
          f.write(result)
        end if !dry_run?
      end

      def warn_about_broken_links(html)
        anchors = extract_anchors(html)
        check_fragment_identifiers(html, anchors)
      end

      def extract_anchors(html)
        # Markdown generates headers with IDs computed from titles.
        anchors = Set.new
        html.scan(/<h\d\s+id="([^"]+)/).flatten.each do |anchor|
          if anchors.member?(anchor)
            puts "*** DUPLICATE ID: '#{anchor}', please make sure that there are no headings with the same name at the same level."
          else
            anchors << anchor
          end
        end

        # Footnotes.
        anchors += Set.new(html.scan(/<p\s+class="footnote"\s+id="([^"]+)/).flatten)
        anchors += Set.new(html.scan(/<sup\s+class="footnote"\s+id="([^"]+)/).flatten)
        anchors
      end

      def check_fragment_identifiers(html, anchors)
        broken_links = []

        html.scan(/<a\s+href="#([^"]+)/).flatten.each do |fragment_identifier|
          next if fragment_identifier == "mainCol" # in layout, jumps to some DIV
          unless anchors.member?(CGI.unescape(fragment_identifier))
            guess = DidYouMean::SpellChecker.new(dictionary: anchors).correct(fragment_identifier).first
            puts "*** BROKEN LINK: ##{fragment_identifier}, perhaps you meant ##{guess}."
            broken_links << "##{fragment_identifier}"
          end
        end

        broken_links
      end
  end
end
