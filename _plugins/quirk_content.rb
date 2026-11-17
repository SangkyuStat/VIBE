# frozen_string_literal: true
#
# QUIRK content loader
# --------------------
# The lab keeps everything that changes often in plain files under content/:
#
#   content/papers.bib     publications (BibTeX / biblatex, straight from the CV)
#   content/people.md      PI, students, alumni (Markdown)
#   content/news.md        news items (Markdown list)
#   content/software.md    R packages (Markdown)
#
# At build time this plugin reads them and fills site.data.publications,
# site.data.members, site.data.news and site.data.software for the templates.
# A mistake in one of these files stops the build with a message that names
# the file and the line, so it is easy to find on GitHub.

module Quirk
  class Error < StandardError; end

  # ------------------------------------------------------------------ text
  module Text
    module_function

    ACCENTS = {
      "'" => { 'a' => 'á', 'e' => 'é', 'i' => 'í', 'o' => 'ó', 'u' => 'ú', 'y' => 'ý', 'c' => 'ć', 'n' => 'ń',
               's' => 'ś', 'z' => 'ź', 'A' => 'Á', 'E' => 'É', 'I' => 'Í', 'O' => 'Ó', 'U' => 'Ú' },
      '`' => { 'a' => 'à', 'e' => 'è', 'i' => 'ì', 'o' => 'ò', 'u' => 'ù', 'A' => 'À', 'E' => 'È' },
      '"' => { 'a' => 'ä', 'e' => 'ë', 'i' => 'ï', 'o' => 'ö', 'u' => 'ü', 'A' => 'Ä', 'O' => 'Ö', 'U' => 'Ü' },
      '^' => { 'a' => 'â', 'e' => 'ê', 'i' => 'î', 'o' => 'ô', 'u' => 'û' },
      '~' => { 'a' => 'ã', 'n' => 'ñ', 'o' => 'õ', 'N' => 'Ñ' },
      '=' => { 'a' => 'ā', 'e' => 'ē', 'i' => 'ī', 'o' => 'ō', 'u' => 'ū' },
      'c' => { 'c' => 'ç', 'C' => 'Ç', 's' => 'ş' },
      'v' => { 'c' => 'č', 's' => 'š', 'z' => 'ž', 'r' => 'ř', 'e' => 'ě', 'C' => 'Č', 'S' => 'Š', 'Z' => 'Ž' },
      'u' => { 'a' => 'ă', 'g' => 'ğ' }
    }.freeze

    # LaTeX as written in .bib files -> plain text.
    def latex_to_text(value)
      t = value.to_s.dup
      t.gsub!(/\\\\/, ' ')                                   # \\ line breaks
      t.gsub!(/\$\\star\$/, '')                              # $\star$
      t.gsub!(/\{?\\([`'"^~=])\s*\{?([A-Za-z])\}?\}?/) { (ACCENTS[Regexp.last_match(1)] || {})[Regexp.last_match(2)] || Regexp.last_match(2) }
      t.gsub!(/\{?\\([cvu])\s*\{([A-Za-z])\}\}?/) { (ACCENTS[Regexp.last_match(1)] || {})[Regexp.last_match(2)] || Regexp.last_match(2) }
      t.gsub!(/\\(?:textbf|textit|emph|textrm|textsc|textsf|mathrm|mathbf|text)\s*\{([^{}]*)\}/, '\1')
      t.gsub!(/\\([&%$#_])/, '\1')
      t.gsub!(/\$([^$]*)\$/, '\1')                          # inline math: keep the letters
      t.gsub!(/\\[a-zA-Z]+\s*/, '')                          # any other command
      t.gsub!('---', '—')
      t.gsub!('--', '–')
      t.delete!('{}')
      t.gsub(/\s+/, ' ').strip
    end

    def esc(s)
      s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
    end

    def cap(s)
      s = s.to_s.strip
      s.empty? ? nil : s[0].upcase + s[1..]
    end

    # Name key used to match papers.bib authors with people.md names.
    def name_key(family, given)
      norm = lambda do |x|
        x.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, '').downcase.gsub(/[^a-z]/, '')
      end
      "#{norm.call(family)}|#{norm.call(given)}"
    end

    # "Lee, Sang Kyu" or "Sang Kyu Lee" -> ["Lee", "Sang Kyu"]
    def split_name(raw)
      n = latex_to_text(raw)
      if n.include?(',')
        parts = n.split(',').map(&:strip)
        family = parts[0]
        given = parts[1..].reject { |p| p =~ /\A(jr|sr|ii|iii|iv)\.?\z/i }.join(' ')
      else
        words = n.split(' ')
        family = words.pop.to_s
        given = words.join(' ')
      end
      [family, given]
    end

    def initials(given)
      given.split(/\s+/).map { |w| w.split('-').map { |p| p.empty? ? '' : "#{p[0]}." }.join('-') }.join(' ')
    end
  end

  # ------------------------------------------------------- markdown files
  # Shared reader for people.md and software.md:
  #   ## Group            starts a group
  #   ### Name            starts an item (a person, a package)
  #   - key: value        a field of that item (empty value = not shown)
  #     - a: b            an indented line under "- key:" (kept for future lists)
  #   other text          free text of that item (not shown at the moment)
  # HTML comments <!-- ... --> are ignored, so they can hold editing notes.
  module Markdownish
    module_function

    def strip_comments(text)
      text.gsub(/<!--.*?-->/m) { |c| "\n" * c.count("\n") }
    end

    def parse(text, file)
      groups = []
      group = nil
      item = nil
      list_key = nil
      strip_comments(text).each_line.with_index(1) do |raw, n|
        line = raw.chomp
        next if line.strip.empty?

        case line
        when /\A#\s/ then next
        when /\A##\s+(.+?)\s*\z/
          group = { 'name' => Regexp.last_match(1), 'items' => [] }
          groups << group
          item = nil
          list_key = nil
        when /\A###\s+(.+?)\s*\z/
          unless group
            group = { 'name' => '', 'items' => [] }
            groups << group
          end
          item = { 'name' => Regexp.last_match(1), 'line' => n, 'fields' => {}, 'lines' => {}, 'lists' => {}, 'body' => [] }
          group['items'] << item
          list_key = nil
        when /\A[-*]\s+([^:]+?)\s*:\s*(.*?)\s*\z/
          raise Error, "#{file} line #{n}: this line must come under a '### Name' heading" unless item

          key = Regexp.last_match(1).downcase.strip
          val = Regexp.last_match(2)
          item['lines'][key] = n
          if val.empty?
            list_key = key
            item['lists'][key] ||= []
          else
            item['fields'][key] = val
            list_key = nil
          end
        when /\A\s+[-*]\s+(.*?)\s*\z/
          raise Error, "#{file} line #{n}: an indented line must come right under a '- key:' line" unless item && list_key

          item['lists'][list_key] << [Regexp.last_match(1), n]
        when /\A[-*]\s+/
          raise Error, "#{file} line #{n}: write this as '- key: value' (the colon is missing)"
        else
          raise Error, "#{file} line #{n}: text must come under a '### Name' heading" unless item

          item['body'] << line.strip
        end
      end
      groups
    end
  end

  # --------------------------------------------------------------- people
  module People
    LINKS = %w[email homepage scholar github linkedin].freeze
    KNOWN = (%w[role title experience degree photo now years interests about] + LINKS + ['name in papers']).freeze
    # Fields that can also be given in Korean as "<key> ko" (e.g. "name ko: ...").
    KOREAN = %w[name title role experience degree interests about now].freeze

    module_function

    def build(groups, file)
      pi = nil
      out = []
      groups.each do |g|
        members = g['items'].map { |it| person(it, file) }
        if g['name'] =~ /principal investigator/i
          pi = members.first
        else
          out << { 'name' => g['name'], 'members' => members }
        end
      end
      raise Error, "#{file}: add a '## Principal Investigator' section with one '### Name' under it" unless pi

      { 'pi' => pi, 'groups' => out }
    end

    def person(it, file)
      f = it['fields']
      (f.keys + it['lists'].keys).uniq.each do |k|
        next if KNOWN.include?(k) || KOREAN.map { |x| "#{x} ko" }.include?(k)

        Jekyll.logger.warn 'QUIRK content:', "#{file} line #{it['lines'][k]}: unknown key '#{k}' (ignored)"
      end
      p = { 'name' => it['name'] }
      %w[role title photo now years about].each { |k| p[k] = f[k] if f[k] }
      %w[experience degree].each do |k|
        [k, "#{k} ko"].each do |key|
          lines = f[key].to_s.split(';') + (it['lists'][key] || []).map(&:first)
          lines = lines.map(&:strip).reject(&:empty?)
          p[key.sub(' ko', '_ko')] = lines unless lines.empty?
        end
      end
      %w[name title role about now].each { |k| p["#{k}_ko"] = f["#{k} ko"] if f["#{k} ko"] }
      p['interests_ko'] = f['interests ko'].split(',').map(&:strip).reject(&:empty?) if f['interests ko']
      p['links'] = LINKS.each_with_object({}) { |k, h| h[k] = f[k] if f[k] }
      p['interests'] = f['interests'].split(',').map(&:strip).reject(&:empty?) if f['interests']
      p['aliases'] = f['name in papers'].split(';').map(&:strip).reject(&:empty?) if f['name in papers']
      p
    end

    # Name keys for the PI and for everyone else (lab members, including alumni).
    # Both are shown the same way in the author lists.
    def keys(members)
      to_keys = lambda do |m|
        ([m['name']] + (m['aliases'] || [])).map { |n| Text.name_key(*Text.split_name(n)) }
      end
      pi = to_keys.call(members['pi'])
      lab = members['groups'].flat_map { |g| g['members'] }.flat_map { |m| to_keys.call(m) }
      [pi, lab - pi]
    end
  end

  # ------------------------------------------------------------- software
  module Software
    module_function

    def build(groups)
      groups.flat_map { |g| g['items'] }.map do |it|
        f = it['fields']
        s = { 'name' => it['name'] }
        %w[role description github cran shiny].each { |k| s[k] = f[k] if f[k] }
        s['description_ko'] = f['description ko'] if f['description ko']
        s['description'] ||= it['body'].join(' ') unless it['body'].empty?
        s
      end
    end
  end

  # ----------------------------------------------------------------- news
  module News
    module_function

    def parse(text, file)
      items = []
      Markdownish.strip_comments(text).each_line.with_index(1) do |raw, n|
        line = raw.strip
        next if line.empty? || line.start_with?('#')

        # Korean text for the item above: an indented "  - ko: ..." line
        if raw =~ /\A\s+[-*]\s+ko\s*:\s*(.+?)\s*\z/
          raise Error, "#{file} line #{n}: a '- ko:' line must come right under a news item" if items.empty?

          items.last['text_ko'] = Regexp.last_match(1)
          next
        end
        raise Error, "#{file} line #{n}: write news as '- 2026-07: what happened'" unless line =~ /\A[-*]\s+(\d{4})-(\d{1,2})\s*:\s*(.+)\z/

        items << { 'date' => format('%s-%02d', Regexp.last_match(1), Regexp.last_match(2).to_i), 'text' => Regexp.last_match(3) }
      end
      items.each_with_index.sort_by { |it, i| [-it['date'].delete('-').to_i, i] }.map(&:first)
    end
  end

  # ------------------------------------------------------------ papers.bib
  module Bib
    Entry = Struct.new(:type, :key, :fields, :line)
    STATUS = '(in press|revision invited.*|major revision.*|minor revision.*|under review.*|submitted.*|accepted.*|to appear.*|forthcoming.*)'
    SKIP_VENUE = /ready to be submitted|in preparation|working paper/i.freeze

    module_function

    # % starts a comment, as in biber, except inside a field value.
    def strip_comments(text)
      out = +''
      depth = 0
      i = 0
      while i < text.length
        c = text[i]
        if c == '\\'
          out << text[i, 2]
          i += 2
          next
        end
        if c == '%' && depth <= 1
          i = text.index("\n", i) || text.length
          next
        end
        depth += 1 if c == '{'
        depth -= 1 if c == '}'
        depth = 0 if depth.negative?
        out << c
        i += 1
      end
      out
    end

    def entries(text, file)
      src = strip_comments(text)
      list = []
      pos = 0
      while (m = /@\s*([A-Za-z]+)\s*\{/.match(src, pos))
        type = m[1].downcase
        line = src[0...m.begin(0)].count("\n") + 1
        i = m.end(0)
        depth = 1
        while i < src.length && depth.positive?
          c = src[i]
          if c == '\\'
            i += 2
            next
          end
          depth += 1 if c == '{'
          depth -= 1 if c == '}'
          i += 1
        end
        raise Error, "#{file} line #{line}: this entry is missing a closing brace }" if depth.positive?

        body = src[m.end(0)...(i - 1)]
        pos = i
        next if %w[string comment preamble].include?(type)

        key, rest = body.split(',', 2)
        list << Entry.new(type, key.to_s.strip, fields(rest.to_s, file, line), line)
      end
      list
    end

    def fields(s, file, line)
      f = {}
      i = 0
      loop do
        i += 1 while i < s.length && s[i] =~ /[\s,]/
        break if i >= s.length

        m = /\G([A-Za-z][\w+\-:.]*)\s*=\s*/.match(s, i)
        raise Error, "#{file} line #{line}: could not read the entry near '#{s[i, 40].to_s.strip}'" unless m

        i = m.end(0)
        val, i = value(s, i)
        f[m[1].downcase] = val
      end
      f
    end

    def value(s, i)
      parts = []
      loop do
        if s[i] == '{'
          depth = 0
          j = i
          while j < s.length
            c = s[j]
            if c == '\\'
              j += 2
              next
            end
            depth += 1 if c == '{'
            depth -= 1 if c == '}'
            j += 1
            break if depth.zero?
          end
          parts << s[(i + 1)...(j - 1)]
          i = j
        elsif s[i] == '"'
          j = i + 1
          depth = 0
          while j < s.length && !(s[j] == '"' && depth.zero?)
            depth += 1 if s[j] == '{'
            depth -= 1 if s[j] == '}'
            j += 1
          end
          parts << s[(i + 1)...j]
          i = j + 1
        else
          m = /\G[^,#}\s]*/.match(s, i)
          parts << m[0]
          i = m.end(0)
        end
        i += 1 while i < s.length && s[i] =~ /\s/
        break unless s[i] == '#'

        i += 1
        i += 1 while i < s.length && s[i] =~ /\s/
      end
      [parts.join, i]
    end

    def split_authors(s)
      out = []
      depth = 0
      start = 0
      i = 0
      while i < s.length
        depth += 1 if s[i] == '{'
        depth -= 1 if s[i] == '}'
        if depth.zero? && (m = /\G\s+and\s+/i.match(s, i))
          out << s[start...i]
          i = m.end(0)
          start = i
          next
        end
        i += 1
      end
      out << s[start..]
      out.map { |n| n.gsub(/\s+/, ' ').strip }.reject(&:empty?)
    end

    # author+an = {1=adv ; 2=equal ; 4=equal,corr}
    def annotations(s)
      marks = Hash.new { |h, k| h[k] = [] }
      s.to_s.split(';').each do |part|
        idx, vals = part.split('=', 2)
        next unless vals && idx.strip =~ /\A\d+\z/

        marks[idx.strip.to_i] += vals.split(',').map { |v| v.strip.downcase }
      end
      marks
    end

    def authors_html(raw, marks, pi_keys, lab_keys)
      shown = split_authors(raw).each_with_index.map do |nm, k|
        family, given = Text.split_name(nm)
        key = Text.name_key(family, given)
        txt = Text.esc(given.empty? ? family : "#{family}, #{Text.initials(given)}")
        m = marks[k + 1]
        txt += '*' if m.include?('equal')
        txt += '<sup>&#9993;</sup>' if m.include?('corr')
        role = pi_keys.include?(key) || lab_keys.include?(key) ? :lab : nil
        txt = %(<span class="lab">#{txt}</span>) if role
        [txt, role]
      end
      if shown.size > 15
        head = shown.first(10).map(&:first)
        tail = shown.drop(10).select { |_, r| r }.map(&:first)
        return (head + (tail.empty? ? [] : ['…'] + tail)).join(', ') + ', et al.'
      end
      list = shown.map(&:first)
      case list.size
      when 0 then ''
      when 1 then list[0]
      when 2 then "#{list[0]} and #{list[1]}"
      else "#{list[0..-2].join(', ')}, and #{list[-1]}"
      end
    end

    # "arXiv:2511.21562, revision invited from Biometrics" -> ["arXiv", "Revision invited from Biometrics", "2511.21562"]
    # "Biometrics, in press"                                -> ["Biometrics", "In press", nil]
    def split_venue(v)
      if (m = v.match(/\AarXiv\s*:?\s*([\w.\/-]+)\s*(?:,\s*(.*))?\z/i))
        return ['arXiv', Text.cap(m[2]), m[1]]
      end
      if (m = v.match(/\A(.+?),\s*#{STATUS}\z/i))
        return [m[1].strip, Text.cap(m[2]), nil]
      end
      return ['', Text.cap(v), nil] if v.match?(/\A#{STATUS}\z/i)

      [v, nil, nil]
    end

    def category(explicit, kw, venue)
      c = explicit.to_s.strip.downcase
      c = 'applications' if c == 'application'
      c = 'preprint' if c == 'preprints'
      return c if %w[methods applications preprint].include?(c)
      return 'preprint' if kw.include?('pre') || venue == 'arXiv'
      return 'applications' if kw.include?('collab')

      'methods'
    end

    def publications(text, file, pi_keys, lab_keys)
      seen = {}
      pubs = []
      entries(text, file).each_with_index do |e, order|
        f = e.fields
        next if seen[e.key]

        seen[e.key] = true
        kw = f['keywords'].to_s.downcase.split(/[,;]/).map(&:strip)
        next if kw.include?('working') || kw.include?('hide') || f['site'].to_s.strip.downcase == 'hide'

        venue_raw = Text.latex_to_text(f['journal'] || f['journaltitle'] || f['booktitle'] || '')
        next if venue_raw.match?(SKIP_VENUE)

        title = Text.latex_to_text(f['title'])
        raise Error, "#{file} line #{e.line}: entry '#{e.key}' has no title" if title.empty?

        year = f['year'].to_s[/\d{4}/] || f['date'].to_s[/\d{4}/]
        raise Error, "#{file} line #{e.line}: entry '#{e.key}' has no year" unless year

        venue, status, arxiv = split_venue(venue_raw)
        venue = Text.latex_to_text(f['venue']) if f['venue']
        status = Text.cap(Text.latex_to_text(f['status'])) if f['status']
        link = (f['link'] || f['url']).to_s.strip
        link = "https://doi.org/#{f['doi'].strip}" if link.empty? && f['doi']
        link = "https://arxiv.org/abs/#{arxiv}" if link.empty? && arxiv
        note = f['award'] || f['addendum']
        pubs << {
          'key' => e.key,
          'title' => title,
          'authors' => authors_html(f['author'].to_s, annotations(f['author+an']), pi_keys, lab_keys),
          'venue' => venue,
          'status' => status,
          'year' => year.to_i,
          'type' => category(f['category'], kw, venue),
          'url' => (link.empty? ? nil : link),
          'note' => (note ? Text.latex_to_text(note) : nil),
          'areas' => f['areas'].to_s.split(/[,;]/).map { |a| a.strip.downcase }.reject(&:empty?),
          'order' => order
        }
      end
      pubs.sort_by { |p| [-p['year'], p['order']] }
    end
  end

  # -------------------------------------------------------------- the hook
  class Loader < Jekyll::Generator
    safe true
    priority :highest

    def generate(site)
      # content/ is read here, not published as files. (It is not in `exclude`,
      # so `jekyll serve` rebuilds the site when one of these files is saved.)
      site.static_files.reject! { |f| f.relative_path.start_with?('/content/') }
      dir = File.join(site.source, 'content')
      members = People.build(Markdownish.parse(read(dir, 'people.md'), 'content/people.md'), 'content/people.md')
      site.data['members'] = members
      site.data['news'] = News.parse(read(dir, 'news.md'), 'content/news.md')
      site.data['software'] = Software.build(Markdownish.parse(read(dir, 'software.md'), 'content/software.md'))
      pi_keys, lab_keys = People.keys(members)
      site.data['publications'] = Bib.publications(read(dir, 'papers.bib'), 'content/papers.bib', pi_keys, lab_keys)
      Jekyll.logger.info 'QUIRK content:', "#{site.data['publications'].size} papers, " \
                                           "#{members['groups'].sum { |g| g['members'].size }} members, " \
                                           "#{site.data['news'].size} news, #{site.data['software'].size} software"
    rescue Quirk::Error => e
      raise Jekyll::Errors::FatalException, "Problem in content files: #{e.message}"
    end

    private

    def read(dir, name)
      path = File.join(dir, name)
      raise Error, "content/#{name} is missing" unless File.exist?(path)

      File.read(path, encoding: 'bom|utf-8')
    end
  end
end
