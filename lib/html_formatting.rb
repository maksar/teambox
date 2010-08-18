module HtmlFormatting
  protected

  include ActionView::Helpers::UrlHelper

  def format_attributes
    self.class.formatted_attributes.each do |attr|
      text = self[attr]

      self["#{attr}_html"] = if text.blank?
        nil
      else
        text = format_markdown_links(text)
        text = format_gfm(text)
        text = format_text(text)
        text = format_usernames(text)
        text = format_links(text)
        white_list_sanitizer.sanitize(text)
      end
    end
  end

  MarkdownLink = /(\[((?:\[[^\]]*\]|[^\[\]])*)\]\([ \t]*()<?(.*?)>?[ \t]*((['"])(.*?)\6[ \t]*)?\))/
  WebDomain    = /^(?:(?:(?:[a-z0-9][a-z0-9-]{0,62}[a-z0-9])|[a-z])\.)+[a-z]{2,6}/i

  def format_markdown_links(body)
    body.gsub(MarkdownLink) do |text|
      anchor  = $2
      link_id = $3
      url     = $4
      title   = $7
      if $4 =~ WebDomain
        "[#{anchor}](http://#{url})"
      else
        text
      end
    end
  end

  # Get @username, like in Twitter, and link it to user path
  def format_usernames(body)
    body.gsub(/\W@([a-z0-9_]+)/) do |text|
      name = $1.downcase

      if 'all' == name
        @mentioned = project.users.confirmed
        text.first + content_tag(:span, '@all', :class => "mention")
      elsif user = project.users.confirmed.find_by_login(name)
        if Comment === self
          @mentioned ||= []
          @mentioned |= [user]
        end
        text.first + link_to("@#{user.login}", "/users/#{user.login}", :class => 'mention')
      else
        text
      end
    end
  end

  def format_text(text)
    RDiscount.new(text).to_html
  end

  def format_links(text)
    auto_link(text) { |text| truncate(text, :length => 80) }
  end

  # Github Flavoured Markdown, from http://github.github.com/github-flavored-markdown/
  def format_gfm(text)
    # Extract pre blocks
    extractions = {}
    text.gsub!(%r{<pre>.*?</pre>}m) do |match|
      md5 = Digest::MD5.hexdigest(match)
      extractions[md5] = match
      "{gfm-extraction-#{md5}}"
    end

    # prevent foo_bar_baz from ending up with an italic word in the middle
    text.gsub!(/(^(?! {4}|\t)\w+_\w+_\w[\w_]*)/) do |x|
      x.gsub('_', '\_') if x.split('').sort.to_s[0..1] == '__'
    end

    # in very clear cases, let newlines become <br /> tags
    text.gsub!(/^[\w\<][^\n]*\n+/) do |x|
      x =~ /\n{2}/ ? x : (x.strip!; x << "  \n")
    end

    # Insert pre block extractions
    text.gsub!(/\{gfm-extraction-([0-9a-f]{32})\}/) do
      "\n\n" + extractions[$1]
    end

    text
  end
end
