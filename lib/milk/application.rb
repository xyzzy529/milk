module Milk
  class Application 
    
    PAGE_PATH_REGEX = /^\/([a-zA-Z0-9_]+(\/[a-zA-Z0-9_]+)*)+\/*$/
    EDIT_PATH_REGEX = /^\/([a-zA-Z0-9_]+(\/[a-zA-Z0-9_]+)*)+\/edit\/*$/
    
    attr_reader :req
    
    def initialize(require_ssl=false)
      @require_ssl = require_ssl
    end
    
    def route
      path = @req.path_info
      
      if path == '/'
        # Special case for root
        path = '/Home'
      end
      
      # Fallback to match everything
      regex = /(.*)/
      
      # Route the request to the right callback
      https = @req.env['HTTPS'] == 'on'
      action = case 
        when @req.get?
          case
            when path == "/logout"
              :logout
            when path =~ EDIT_PATH_REGEX
              regex = EDIT_PATH_REGEX
              if @require_ssl && !https
                :https_redirect
              else
                :edit
              end
            when path =~ PAGE_PATH_REGEX
              regex = PAGE_PATH_REGEX
              :view
          end
        when @req.delete?
          if path =~ PAGE_PATH_REGEX
            regex = PAGE_PATH_REGEX
            :delete
          end
        when @req.post?
          if path == '/login'
            :login
          elsif path == '/form_submit'
            :form_submit
          elsif path =~ PAGE_PATH_REGEX
            regex = PAGE_PATH_REGEX
            :preview
          end
        when @req.put?
          if path =~ PAGE_PATH_REGEX
            regex = PAGE_PATH_REGEX
            :save
          end
      end || :not_found
      
      page_name = regex.match(path)[1]
      
      if (action == :view || action == :edit)
        begin 
          page = Milk::Page.find(page_name)
        rescue Milk::PageNotFoundError
          action = :not_found
        end
      end

      if (action == :preview || action == :save)
        page = Milk::Page.json_unserialize(YAML.load(@req.body.read), page_name)
      end
      
      if !@user && [:edit, :save, :delete].include?(action)
        action = :login_form
      end

      return action, page_name, page
    end
    
    def encode(value)
      require 'base64'
      len = Milk::SECRET.length
      result = (0...value.length).collect { |i| value[i].ord ^ Milk::SECRET[i%len].ord }
      Base64.encode64(result.pack("C*"))
    end
    
    def decode(code)
      require 'base64'
      len = Milk::SECRET.length
      value = Base64.decode64(code)
      result = (0...value.length).collect { |i| value[i].ord ^ Milk::SECRET[i%len].ord }
      result.pack("C*")
    end
    
    def hash(email, password)
      require 'digest/md5'
      Digest::MD5.hexdigest("#{password}")
    end
    
    def send_email(from, from_alias, to, to_alias, subject, message)
	    msg = <<END_OF_MESSAGE
From: #{from_alias} <#{from}>
To: #{to_alias} <#{to}>
Subject: #{subject}

#{message}
END_OF_MESSAGE
      require 'net/smtp'	
	    Net::SMTP.start('localhost') do |smtp|
		    smtp.send_message msg, from, to
	    end
    end

    def form_submit
      instr = eval(decode(@req.params['instructions']))
      p = @req.params.reject { |k,v| k == 'instructions'}
      print instr.inspect+"\n"
      print instr[:sendto].inspect+"\n"
      print instr[:sendto].split(' ').inspect+"\n"
      instr[:sendto].split(' ').each do |email|
        continue unless u = USERS[email]
        send_email("milk@#{@req.host}", "Milk Server at #{@req.host}", email, u[:name], "Someone messaged you from #{@req.referer}", YAML.dump(p))
      end
      @resp.redirect(instr[:dest])
    end
    
    def logout
      @resp.delete_cookie('auth', :path => "/")
      @resp.redirect(@req.params['dest'])
    end
    
    def flash(message=nil)
      @resp.delete_cookie('flash', :path => "/") unless message
      @resp.set_cookie('flash', :path => "/", :value => message) if message
      @req.cookies['flash']
    end
    
    def login
      email = @req.params['email']
      if email.length > 0
        user = USERS[email]
        if user
          expected = user[:hash]
          actual = hash(email, @req.params['password'])
          if actual == expected
            @resp.set_cookie('auth', :path => "/", :value => encode(email), :secure=>@require_ssl, :httponly=>true)
          else
            flash "Incorrect password for user #{email}"
          end
        else
          flash "User #{email} not found"
        end
      else
        flash "Please enter user email and password"
      end
      @resp.redirect(@req.params['dest'])
    end
    
    def load_user
      @user = nil
      if current = @req.cookies['auth']
        email = decode(current)
        @user = USERS[email]
        @resp.delete_cookie('auth', :path => "/") unless @user
      end
    end
    
    def render_dependencies(deps=[])
      deps << @action
      list = []
      deps.each do |target|
        load_deps(list, target)
      end
      list.uniq!
      haml("dependencies", :list => list)
    end
    
    def load_deps(list, target)
      return list unless DEPENDENCY_TREE[target]
      DEPENDENCY_TREE[target].each do |more|
        if more.class == Symbol
          load_deps(list, more)
        else
          list << more
        end
      end
    end
    
    
    # Rack call interface
    def call(env)
      @req = Rack::Request.new(env)
      @resp = Rack::Response.new
      load_user
      
      # Route the request
      @action, page_name, @page = route
      
      # Send proper mime types for browsers that claim to accept it
      @resp["Content-Type"] = 
      if env['HTTP_ACCEPT'].include? "application/xhtml+xml"
        "application/xhtml+xml"
        "text/html"
      else
        "text/html"
      end

      case @action
        when :not_found
          @resp.status = 404
          page = Milk::Page.find('NotFound')
          Milk::Application.join_tree(page, self)
          @action = :view
          @resp.write page.view
        when :view
          Milk::Application.join_tree(@page, self)
          html = @page.view
          @page.save_to_cache(html) if Milk::USE_CACHE
          @resp.write html
        when :https_redirect
          @resp.redirect('https://' +  @req.host + @req.fullpath)
        when :http_redirect
          @resp.redirect('http://' +  @req.host + @req.fullpath)
        when :edit
          Milk::Application.join_tree(@page, self)
          @resp.write @page.edit
        when :save
          Milk::Application.join_tree(@page, self)
          yaml = @page.save
          @page.save_to_cache if Milk::USE_CACHE
          @resp.write yaml
        when :preview
          Milk::Application.join_tree(@page, self)
          @resp.write @page.preview
        when :login_form
          @resp.write(haml("login"))
        when :login
          login
        when :logout
          logout
        when :form_submit
          form_submit
        when :access_denied
          @resp.staus = 403
          @resp.write "Access Denied"
        else
          @resp.status = 500
          @resp.write @action.to_s
      end
      @resp.finish
    end    

    # method that walks an object linking Milk objects to eachother
    def self.join_tree(obj, parent)
      if [Milk::Page, Milk::Component, Milk::Application].any? {|klass| obj.kind_of? klass}
        obj.parent = parent
        obj.instance_variables.each do |name|
          var = obj.instance_variable_get(name)
          if var.class == Array
            var.each do |subvar|
              join_tree(subvar, obj)
            end
          end
        end
      end
    end
    
  end
  
  class PageNotFoundError < Exception
  end
end

