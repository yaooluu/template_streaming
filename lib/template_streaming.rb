module TemplateStreaming
  class << self
    def configure(config)
      config.each do |key, value|
        send "#{key}=", value
      end
    end

    attr_accessor :autosweep_flash
  end

  self.autosweep_flash = true

  module Controller
    def self.included(base)
      base.class_eval do
        alias_method_chain :render, :template_streaming
        helper_method :flush, :push

        include ActiveSupport::Callbacks
        define_callbacks :when_streaming_template
      end
    end

    def render_with_template_streaming(*args, &block)
      with_template_streaming_condition(*args) do |condition|
        if condition
          @performed_render = true
          check_thin_support
          @streaming_body = StreamingBody.new(progressive_rendering_threshold) do
            @performed_render = false
            last_piece = render_without_template_streaming(*args, &block)
            # The original render will clobber our response.body, so
            # we must push the buffer ourselves.
            push last_piece
          end
          response.body = @streaming_body
          response.prepare!
          flash if TemplateStreaming.autosweep_flash
          run_callbacks :when_streaming_template

          # Normally, @_flash is removed after #perform_action, which
          # means calling #flash in the view would cause a new
          # FlashHash to be constructed. On top of that, the flash is
          # swept on construction, which results in sweeping the flash
          # twice, obliterating its contents.
          #
          # So, we preserve the flash here under a different ivar, and
          # override the #flash helper to return it.
          if defined?(@_flash)
            @template_streaming_flash = @_flash
          end
        else
          render_without_template_streaming(*args, &block)
        end
      end
    end

    #
    # Flush the current template's output buffer out to the client
    # immediately.
    #
    def flush
      unless @template.output_buffer.nil?
        push @template.output_buffer.slice!(0..-1)
      end
    end

    #
    # Push the given data to the client immediately.
    #
    def push(data)
      @streaming_body.push(data)
      flush_thin
    end

    def template_streaming_flash # :nodoc:
      @template_streaming_flash
    end

    private # --------------------------------------------------------

    #
    # Yield true if we should intercept this render call, false
    # otherwise.
    #
    def with_template_streaming_condition(*args)
      @render_stack_height ||= 0
      @render_stack_height += 1
      begin
        # Only install our StreamingBody in the toplevel #render call.
        @render_stack_height == 1 or
          return yield(false)

        if (options = args.last).is_a?(Hash)
          yield((UNSTREAMABLE_KEYS & options.keys).empty?)
        else
          yield(args.first != :update)
        end
      ensure
        @render_stack_height -= 1
      end
    end

    UNSTREAMABLE_KEYS = [:text, :xml, :json, :js, :update, :nothing]

    #
    # The number of bytes that must be received by the client before
    # anything will be rendered.
    #
    def progressive_rendering_threshold
      response.header['Content-type'] =~ %r'\Atext/html' or
        return 0

      case request.env['HTTP_USER_AGENT']
      when /MSIE/
        255
      when /Chrome/
        # Note: Chrome's UA string includes "Safari", so it must precede.
        2048
      when /Safari/
        1024
      else
        0
      end
    end

    def check_thin_support
      return if defined?(@thin_support_found)
      if (@thin_callback = request.env['async.callback'])
        begin
          require 'event_machine_flush'
          @thin_support_found = true
        rescue LoadError
          raise "Template Streaming on Thin requires the event_machine_flush gem."
        end
      end
    end

    #
    # Force EventMachine to flush its buffer when using Thin.
    #
    def flush_thin
      @thin_callback and
        EventMachineFlush.flush(@thin_callback.receiver)
    end
  end

  # Only prepare once.
  module Response
    def self.included(base)
      base.alias_method_chain :prepare!, :template_streaming
      base.alias_method_chain :set_content_length!, :template_streaming
    end

    def prepare_with_template_streaming!
      return if defined?(@prepared)
      prepare_without_template_streaming!
      @prepared = true
    end

    def set_content_length_with_template_streaming!
      if body.is_a?(StreamingBody)
        # pass
      else
        set_content_length_without_template_streaming!
      end
    end
  end

  module View
    def self.included(base)
      base.alias_method_chain :_render_with_layout, :template_streaming
      base.alias_method_chain :flash, :template_streaming
    end

    def _render_with_layout_with_template_streaming(options, local_assigns, &block)
      with_prelayout prelayout_for(options), local_assigns do
        _render_with_layout_without_template_streaming(options, local_assigns, &block)
      end
    end

    def with_prelayout(prelayout, locals, &block)
      if prelayout
        begin
          @_proc_for_layout = lambda do
            # nil out @_proc_for_layout else rendering with the layout will call it again.
            @_proc_for_layout, original_proc_for_layout = nil, @_proc_for_layout
            begin
              block.call
            ensure
              @_proc_for_layout = original_proc_for_layout
            end
          end
          render(:file => prelayout, :locals => locals)
        ensure
          @_proc_for_layout = nil
        end
      else
        yield
      end
    end

    def prelayout_for(options)
      layout = options[:layout] or
        return nil
      # Views can call #render with :layout to render a layout
      # *partial* which we don't want to interfere with. Only the
      # interlal toplevel #render calls :layout with an
      # ActionView::Template
      layout.is_a?(ActionView::Template) or
        return nil
      view_paths.find_template('pre' + layout.path_without_format_and_extension, layout.format)
    rescue ActionView::MissingTemplate
    end

    def flash_with_template_streaming # :nodoc:
      # Override ActionView::Base#flash to prevent a double-sweep.
      controller.instance_eval { @template_streaming_flash || flash }
    end
  end

  class StreamingBody
    def initialize(threshold, &block)
      @process = block
      @bytes_to_threshold = threshold
    end

    def each(&block)
      @push = block
      @process.call
    end

    def push(data)
      if @bytes_to_threshold > 0
        @push.call(data + padding)
        @bytes_to_threshold = 0
      else
        @push.call(data)
      end
    end

    private  # -------------------------------------------------------

    def padding
      content_length = [@bytes_to_threshold - 7, 0].max
      "<!--#{'-'*content_length}-->"
    end
  end

  ActionView::Base.send :include, View
  ActionController::Base.send :include, Controller
  ActionController::Response.send :include, Response
end
