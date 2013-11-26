=begin
    Copyright 2010-2014 Tasos Laskos <tasos.laskos@gmail.com>
    All rights reserved.
=end

module Arachni
module Check

#
# Included by {Check::Base} and provides helper audit methods to all checks.
#
# There are 3 main types of audit and analysis techniques available:
#
# * {Arachni::Element::Capabilities::Auditable::Taint Taint analysis} -- {#audit}
# * {Arachni::Element::Capabilities::Auditable::Timeout Timeout analysis} -- {#audit_timeout}
# * {Arachni::Element::Capabilities::Auditable::RDiff Differential analysis} -- {#audit_rdiff}
#
# It should be noted that actual analysis takes place at the element level,
# and to be more specific, the {Arachni::Element::Capabilities::Auditable} element level.
#
# It also provides:
#
# * Discovery helpers for checking and logging the existence of remote files.
#   * {#log_remote_file}
#   * {#remote_file_exist?}
#   * {#log_remote_file_if_exists}
# * Pattern matching helpers for checking and logging the existence of strings
#   in responses or in the body of the page that's being audited.
#   * {#match_and_log}
# * General {Arachni::Issue} logging helpers.
#   * {#log}
#   * {#log_issue}
#   * {#register_results}
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
#
module Auditor
    def self.reset
        audited.clear
    end

    def self.has_timeout_candidates?
        Element::Capabilities::Auditable::Timeout.has_candidates?
    end
    def self.timeout_audit_run
        Element::Capabilities::Auditable::Timeout.run
    end

    #
    # @param    [#to_s]  id  Identifier of the object to be marked as audited.
    #
    # @see #audited?
    #
    def audited( id )
        Auditor.audited << "#{self.class}-#{id}"
    end

    #
    # @param    [#to_s] id  Identifier of the object to be checked.
    #
    # @return   [Bool]  `true` if audited, `false` otherwise.
    #
    # @see #audited
    #
    def audited?( id )
        Auditor.audited.include?( "#{self.class}-#{id}" )
    end

    def self.included( m )
        m.class_eval do
            def self.issue_counter
                @issue_counter ||= 0
            end

            def self.issue_counter=( int )
                @issue_counter = int
            end

            def increment_issue_counter
                self.class.issue_counter += 1
            end

            def issue_limit_reached?( count = max_issues )
                self.class.issue_limit_reached?( count )
            end

            def self.issue_limit_reached?( count = max_issues )
                issue_counter >= count if !count.nil?
            end

            def self.max_issues
                info[:max_issues]
            end
        end
    end

    def max_issues
        self.class.max_issues
    end

    #
    # Holds constant bitfields that describe the preferred formatting
    # of injection strings.
    #
    Format = Element::Capabilities::Mutable::Format

    # Default audit options.
    OPTIONS = {
        #
        # Elements to audit.
        #
        # If no elements have been passed to audit methods, candidates will be
        # determined by {#each_candidate_element}.
        #
        elements: [Element::LINK, Element::FORM,
                   Element::COOKIE, Element::HEADER,
                   Element::BODY],

        #
        # If set to `true` the HTTP response will be analyzed for new elements.
        # Be careful when enabling it, there'll be a performance penalty.
        #
        # If set to `false`, no training is going to occur.
        #
        # If set to `nil`, when the Auditor submits a form with original or
        # sample values this option will be overridden to `true`
        #
        train:    nil
    }

    #
    # *REQUIRED*
    #
    # @return   [Arachni::Page]  Page object you want to audit.
    # @abstract
    #
    attr_reader :page

    #
    # *REQUIRED*
    #
    # @return   [Arachni::Framework]
    #
    # @abstract
    #
    attr_reader :framework

    #
    # *OPTIONAL*
    #
    # Allows checks to ignore multi-Instance scope restrictions in order to
    # audit elements that are not on the sanctioned whitelist.
    #
    # @return   [Bool]
    #
    # @abstract
    #
    def override_instance_scope?
        false
    end

    # @return   [HTTP::Client]
    def http
        HTTP::Client
    end

    #
    # Just a delegator, logs an array of issues.
    #
    # @param    [Array<Arachni::Issue>]     issues
    #
    # @see Arachni::Check::Manager#register_results
    #
    def register_results( issues )
        return if issue_limit_reached?
        self.class.issue_counter += issues.size

        framework.checks.register_results( issues )
    end

    #
    # @note Ignores custom 404 responses.
    #
    # Logs a remote file or directory if it exists.
    #
    # @param    [String]    url Resource to check.
    # @param    [Bool]      silent
    #   If `false`, a message will be printed to stdout containing the status of
    #   the operation.
    # @param    [Proc]      block
    #   Called if the file exists, just before logging the issue, and is passed
    #   the HTTP response.
    #
    # @return   [Object]
    #   * `nil` if no URL was provided.
    #   * `false` if the request couldn't be fired.
    #   * `true` if everything went fine.
    #
    # @see #remote_file_exist?
    #
    def log_remote_file_if_exists( url, silent = false, &block )
        return nil if !url

        print_status( "Checking for #{url}" ) if !silent
        remote_file_exist?( url ) do |bool, res|
            print_status( 'Analyzing response for: ' + url ) if !silent
            next if !bool

            block.call( res ) if block_given?
            log_remote_file( res )

            # If the file exists let the trainer parse it since it may contain
            # brand new data to audit.
            framework.trainer.push( res )
        end
         true
    end
    alias :log_remote_directory_if_exists :log_remote_file_if_exists

    #
    # @note Ignores custom 404 responses.
    #
    # Checks whether or not a remote resource exists.
    #
    # @param    [String]    url Resource to check.
    # @param    [Block] block
    #   Block to be passed  `true` if the resource exists, `false` otherwise.
    #
    # @return   [Object]
    #   * `nil` if no URL was provided.
    #   * `false` if the request couldn't be fired.
    #   * `true` if everything went fine.
    #
    def remote_file_exist?( url, &block )
        req  = http.get( url, performer: self )
        return false if !req

        req.on_complete do |res|
            if res.code != 200
                block.call( false, res )
            else
                http.custom_404?( res ) { |bool| block.call( !bool, res ) }
            end
        end
        true
    end
    alias :remote_file_exists? :remote_file_exist?

    #
    # Logs the existence of a remote file as an issue.
    #
    # @param    [HTTP::Response]    res
    # @param    [Bool]      silent
    #   If `false`, a message will be printed to stdout containing the status of
    #   the operation.
    #
    # @see #log_issue
    #
    def log_remote_file( res, silent = false )
        url = res.url
        filename = File.basename( res.parsed_url.path )

        log_issue(
            url:      url,
            injected: filename,
            id:       filename,
            elem:     Element::PATH,
            response: res.body,
            headers:  {
                request:  res.request.headers,
                response: res.headers,
            }
        )

        print_ok( "Found #{filename} at #{url}" ) if !silent
    end
    alias :log_remote_directory :log_remote_file

    #
    # Helper method for issue logging.
    #
    # @param    [Hash]  opts    Issue options ({Issue}).
    #
    # @see Arachni::Check::Base#register_results
    #
    def log_issue( opts )
        # register the issue
        register_results( [ Issue.new( opts.merge( self.class.info ) ) ] )
    end

    #
    # Matches an array of regular expressions against a string and logs the
    # result as an issue.
    #
    # @param    [Array<Regexp>]     regexps
    #   Array of regular expressions to be tested.
    # @param    [String]            string
    #   String against which the `regexps` will be matched.
    #   (If no string has been provided the {#page} body will be used and, for
    #   good measure, `regexps` will also be matched against
    #   {HTTP::Response#headers} as well.)
    # @param    [Block] block
    #   Block to verify matches before logging, must return `true`/`false`.
    #
    def match_and_log( regexps, string = page.body, &block )
        # make sure that we're working with an array
        regexps = [regexps].flatten

        elems = self.class.info[:elements]
        elems = OPTIONS[:elements] if !elems || elems.empty?

        regexps.each do |regexp|
            string.scan( regexp ).flatten.uniq.each do |match|

                next if !match
                next if block && !block.call( match )

                log(
                    regexp:  regexp,
                    match:   match,
                    element: Element::BODY
                )
            end if elems.include? Element::BODY

            next if string != page.body

            page.response.headers.each do |k,v|
                next if !v

                v.to_s.scan( regexp ).flatten.uniq.each do |match|
                    next if !match
                    next if block && !block.call( match )

                    log(
                        var:     k,
                        regexp:  regexp,
                        match:   match,
                        element: Element::HEADER
                    )
                end
            end if elems.include? Element::HEADER

        end
    end

    #
    # Populates and logs an {Arachni::Issue} based on data from `opts` and `res`.
    #
    # @param    [Hash]  options
    #   As passed to blocks by audit methods.
    # @param    [HTTP::Response]    response
    #   Optional HTTP response, defaults to page data.
    #
    def log( options, response = page.response )
        url     = options[:action]  || response.url
        var     = options[:altered] || options[:var]
        element = options[:element] || options[:elem]

        msg = "In #{element}"
        msg << " input '#{var}'" if var
        print_ok "#{msg} ( #{url} )"

        print_verbose( "Injected string:\t#{options[:injected]}" )         if options[:injected]
        print_verbose( "Verified string:\t#{options[:match]}" )            if options[:match]
        print_verbose( "Matched regular expression: #{options[:regexp]}" ) if options[:regexp]
        print_debug( "Request ID: #{response.request.id}" )
        print_verbose( '---------' )                                       if only_positives?

        # Platform identification by vulnerability.
        platform_type = nil
        if (platform = options[:platform])
            Platform::Manager[url] << platform if Options.fingerprint?
            platform_type = Platform::Manager[url].find_type( platform )
        end

        log_issue(
            var:           var,
            url:           url,
            platform:      platform,
            platform_type: platform_type,
            injected:      options[:injected],
            id:            options[:id],
            regexp:        options[:regexp],
            regexp_match:  options[:match],
            elem:          element,
            verification:  !!options[:verification],
            remarks:       options[:remarks],
            method:        response.request.method.to_s.upcase,
            response:      response.body,
            opts:          options,
            headers:       {
                request:   response.request.headers,
                response:  response.headers,
            }
        )
    end

    # @see Arachni::Check::Base#preferred
    # @see Arachni::Check::Base.prefer
    # @abstract
    def preferred
        []
    end

    # This is called right before an {Arachni::Element} is audited and is used
    # to determine whether to skip it or not.
    #
    # Running checks can override this as they wish *but* at their own peril.
    #
    # @param    [Arachni::Element]  elem
    #
    # @return   [Boolean]
    #   `true` if the element should be skipped, `false` otherwise.
    def skip?( elem )
        # Don't audit elements which have been already logged as vulnerable
        # either by us or preferred checks.
        (preferred | [shortname]).each do |mod|
            next if !framework.checks.include?( mod )
            issue_id = elem.provisioned_issue_id( framework.checks[mod].name )
            return true if framework.checks.issue_set.include?( issue_id )
        end

        false
    end

    # Passes each element prepared for audit to the block.
    #
    # If no element types have been specified in `opts`, it will use the elements
    # from the check's {Base.info} hash.
    #
    # If no elements have been specified in `opts` or {Base.info}, it will use the
    # elements in {OPTIONS}.
    #
    # @param  [Hash]    opts
    # @option opts  [Array]  :elements
    #   Element types to audit (see {OPTIONS}`[:elements]`).
    #
    # @yield       [element]  Each candidate element.
    # @yieldparam [Arachni::Element]
    def each_candidate_element( opts = {} )
        if !opts.include?( :elements) || !opts[:elements] || opts[:elements].empty?
            opts[:elements] = self.class.info[:elements]
        end

        if !opts.include?( :elements) || !opts[:elements] || opts[:elements].empty?
            opts[:elements] = OPTIONS[:elements]
        end

        elements = []
        opts[:elements].each do |elem|
            next if !Options.audit?( elem )

            elements |= case elem
                when Element::LINK
                    page.links

                when Element::FORM
                    page.forms

                when Element::COOKIE
                    page.cookies

                when Element::HEADER
                    page.headers

                when Element::BODY
                else
                    fail ArgumentError, "Unknown element: #{elem}"
            end
        end

        while (e = elements.pop)
            next if e.inputs.empty?
            d = e.dup
            d.auditor = self
            yield d
        end
    end

    #
    # If a block has been provided it calls {Arachni::Element::Capabilities::Auditable#audit}
    # for every element, otherwise, it defaults to {#audit_taint}.
    #
    # Uses {#each_candidate_element} to decide which elements to audit.
    #
    # @see OPTIONS
    # @see Arachni::Element::Capabilities::Auditable#audit
    # @see #audit_taint
    #
    def audit( payloads, opts = {}, &block )
        opts = OPTIONS.merge( opts )
        if !block_given?
            audit_taint( payloads, opts )
        else
            each_candidate_element( opts ) { |e| e.audit( payloads, opts, &block ) }
        end
    end

    #
    # Provides easy access to element auditing using simple taint analysis
    # and automatically logs results.
    #
    # Uses {#each_candidate_element} to decide which elements to audit.
    #
    # @see OPTIONS
    # @see Arachni::Element::Capabilities::Auditable::Taint
    #
    def audit_taint( payloads, opts = {} )
        opts = OPTIONS.merge( opts )
        each_candidate_element( opts ) { |e| e.taint_analysis( payloads, opts ) }
    end

    #
    # Audits elements using differential analysis and automatically logs results.
    #
    # Uses {#each_candidate_element} to decide which elements to audit.
    #
    # @see OPTIONS
    # @see Arachni::Element::Capabilities::Auditable::RDiff
    #
    def audit_rdiff( opts = {}, &block )
        opts = OPTIONS.merge( opts )
        each_candidate_element( opts ) { |e| e.rdiff_analysis( opts, &block ) }
    end

    #
    # Audits elements using timing attacks and automatically logs results.
    #
    # Uses {#each_candidate_element} to decide which elements to audit.
    #
    # @see OPTIONS
    # @see Arachni::Element::Capabilities::Auditable::Timeout
    #
    def audit_timeout( payloads, opts = {} )
        opts = OPTIONS.merge( opts )
        each_candidate_element( opts ) { |e| e.timeout_analysis( payloads, opts ) }
    end

    private

    #
    # Helper `Set` for checks which want to keep track of what they've audited
    # by themselves.
    #
    # @return   [Set]
    #
    # @see #audited?
    # @see #audited
    #
    def self.audited
        @audited ||= Support::LookUp::HashSet.new
    end

end

end
end
