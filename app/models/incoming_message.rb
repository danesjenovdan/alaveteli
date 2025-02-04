# == Schema Information
# Schema version: 20220210120801
#
# Table name: incoming_messages
#
#  id                             :integer          not null, primary key
#  info_request_id                :integer          not null
#  created_at                     :datetime         not null
#  updated_at                     :datetime         not null
#  raw_email_id                   :integer          not null
#  cached_attachment_text_clipped :text
#  cached_main_body_text_folded   :text
#  cached_main_body_text_unfolded :text
#  subject                        :text
#  from_email_domain              :text
#  valid_to_reply_to              :boolean
#  last_parsed                    :datetime
#  from_name                      :text
#  sent_at                        :datetime
#  prominence                     :string           default("normal"), not null
#  prominence_reason              :text
#  from_email                     :text
#

# models/incoming_message.rb:
# An (email) message from really anybody to be logged with a request. e.g. A
# response from the public body.
#
# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# TODO
# Move some of the (e.g. quoting) functions here into rblib, as they feel
# general not specific to IncomingMessage.

require 'rexml/document'
require 'zip'

class IncomingMessage < ApplicationRecord
  include AdminColumn
  include MessageProminence
  include CacheAttributesFromRawEmail

  MAX_ATTACHMENT_TEXT_CLIPPED = 1000000 # 1Mb ish

  belongs_to :info_request,
             inverse_of: :incoming_messages,
             counter_cache: true

  validates_presence_of :info_request

  validates_presence_of :raw_email

  has_many :outgoing_message_followups,
           :inverse_of => :incoming_message_followup,
           :foreign_key => 'incoming_message_followup_id',
           :class_name => 'OutgoingMessage',
           :dependent => :nullify
  has_many :foi_attachments,
           -> { order(:id) },
           inverse_of: :incoming_message,
           dependent: :destroy,
           autosave: true
  # never really has many info_request_events, but could in theory
  has_many :info_request_events,
           :dependent => :destroy,
           :inverse_of => :incoming_message

  belongs_to :raw_email,
             :inverse_of => :incoming_message,
             :dependent => :destroy

  after_destroy :update_request
  after_update :update_request
  before_destroy :destroy_email_file

  scope :pro, -> { joins(:info_request).merge(InfoRequest.pro) }
  scope :unparsed, -> { where(last_parsed: nil) }

  cache_from_raw_email :subject, :sent_at,
                       :from_name, :from_email, :from_email_domain,
                       :valid_to_reply_to

  delegate :message_id, to: :raw_email
  delegate :multipart?, to: :raw_email
  delegate :parts, to: :raw_email
  delegate :legislation, to: :info_request

  # Given that there are in theory many info request events, a convenience
  # method for getting the response event.
  def response_event
    info_request_events.where(event_type: 'response').first
  end

  def parse_raw_email!(force = nil)
    # The following fields may be absent; we treat them as cached
    # values in case we want to regenerate them (due to mail
    # parsing bugs, etc).
    if self.raw_email.nil?
      raise "Incoming message id=#{id} has no raw_email"
    end
    if (!force.nil? || self.last_parsed.nil?)
      ActiveRecord::Base.transaction do
        extract_attachments
        self.sent_at = raw_email.date || created_at
        self.subject = raw_email.subject
        self.from_name = raw_email.from_name
        self.from_email = raw_email.from_email || ''
        self.from_email_domain = raw_email.from_email_domain || ''
        self.valid_to_reply_to = raw_email.valid_to_reply_to?
        self.last_parsed = Time.zone.now
        self.save!
      end
    end
  end

  def destroy_email_file
    raw_email.destroy_file_representation!
  end

  alias_method :valid_to_reply_to?, :valid_to_reply_to

  def mail_from
    warn %q([DEPRECATION] IncomingMessage#mail_from will be removed in 0.42. It
            has been replaced by IncomingMessage#from_name).squish
    from_name
  end

  # Public: The display name of the email sender with the associated
  # InfoRequest's censor rules applied.
  #
  # Example:
  #
  #   # Given a CensorRule that redacts the word 'Person':
  #
  #   incoming_message.from_name
  #   # => FOI Person
  #
  #   incoming_message.safe_from_name
  #   # => FOI [REDACTED]
  #
  # Returns a String
  def safe_mail_from
    warn %q([DEPRECATION] IncomingMessage#safe_mail_from will be removed in
            0.42. It has been replaced by IncomingMessage#safe_from_name).squish
    safe_from_name
  end

  def safe_from_name
    info_request.apply_censor_rules_to_text(from_name) if from_name
  end

  def mail_from_domain
    warn %q([DEPRECATION] IncomingMessage#mail_from_domain will be removed in
            0.42. It has been replaced by
            IncomingMessage#from_email_domain).squish
    from_email_domain
  end

  def specific_from_name?
    !safe_from_name.nil? && safe_from_name.strip != info_request.public_body.name.strip
  end

  def from_public_body?
    safe_from_name.nil? || (from_email_domain == info_request.public_body.request_email_domain)
  end

  # This method updates the cached column of the InfoRequest that
  # stores the last created_at date of relevant events
  # when updating an IncomingMessage associated with the request
  def update_request
    info_request.update_last_public_response_at
  end

  def destroy_raw_email
    raw_email.destroy
  end

  # And look up by URL part number and display filename to get an attachment
  # TODO: relies on extract_attachments calling MailHandler.ensure_parts_counted
  # The filename here is passed from the URL parameter, so it's the
  # display_filename rather than the real filename.
  def self.get_attachment_by_url_part_number_and_filename(attachments, found_url_part_number, display_filename)
    attachment_by_part_number = attachments.detect { |a| a.url_part_number == found_url_part_number }
    if attachment_by_part_number && attachment_by_part_number.display_filename == display_filename
      # Then the filename matches, which is fine:
      attachment_by_part_number
    else
      # Otherwise if the URL part number and filename don't
      # match - this is probably due to a reparsing of the
      # email.  In that case, try to find a unique matching
      # filename from any attachment.
      attachments_by_filename = attachments.select { |a|
        a.display_filename == display_filename
      }
      if attachments_by_filename.length == 1
        attachments_by_filename[0]
      else
        nil
      end
    end
  end

  def self.get_attachment_by_url_part_number_and_filename!(
    attachments, found_url_part_number, display_filename
  )
    attachment = get_attachment_by_url_part_number_and_filename(
      attachments, found_url_part_number, display_filename
    )

    return unless attachment

    # check filename in URL matches that in database (use a censor rule if you
    # want to change a filename)
    if attachment.display_filename != display_filename &&
       attachment.old_display_filename != display_filename
      msg = 'please use same filename as original file has, display: '
      msg += "'#{ attachment.display_filename }' "
      msg += 'old_display: '
      msg += "'#{ attachment.old_display_filename }' "
      msg += 'original: '
      msg += "'#{ display_filename }'"
      raise ActiveRecord::RecordNotFound, msg
    end

    attachment
  end

  def apply_masks(text, content_type)
    mask_options = { :censor_rules => info_request.applicable_censor_rules,
                     :masks => info_request.masks }
    AlaveteliTextMasker.apply_masks(text, content_type, mask_options)
  end

  # Lotus notes quoting yeuch!
  def remove_lotus_quoting(text, replacement = "FOLDED_QUOTED_SECTION")
    text = text.dup
    return text if self.info_request.user_name.nil?
    name = Regexp.escape(self.info_request.user_name)

    # To end of message sections
    text.gsub!(/^\s?#{name}[^\n]+\n([^\n]+\n)?\s?Sent by:[^\n]+\n.*/im, "\n\n" + replacement)

    # Some other sort of forwarding quoting
    text.gsub!(/^\s?#{name}\s+To\s+FOI requests at.*/im, "\n\n" + replacement)


    # http://www.whatdotheyknow.com/request/229/response/809
    text.gsub!(/^\s?From: [^\n]+\n\s?Sent: [^\n]+\n\s?To:\s+['"]?#{name}['"]?\n\s?Subject:.*/im, "\n\n" + replacement)


    return text

  end


  # Remove quoted sections from emails (eventually the aim would be for this
  # to do as good a job as GMail does) TODO: bet it needs a proper parser
  # TODO: and this FOLDED_QUOTED_SECTION stuff is a mess
  def self.remove_quoted_sections(text, replacement = "FOLDED_QUOTED_SECTION")
    text = text.dup
    replacement = "\n" + replacement + "\n"

    # First do this peculiar form of quoting, as the > single line quoting
    # further below messes with it. Note the carriage return where it wraps -
    # this can happen anywhere according to length of the name/email. e.g.
    # >>> D K Elwell <[email address]> 17/03/2008
    # 01:51:50 >>>
    # http://www.whatdotheyknow.com/request/71/response/108
    # http://www.whatdotheyknow.com/request/police_powers_to_inform_car_insu
    # http://www.whatdotheyknow.com/request/secured_convictions_aided_by_cct
    multiline_original_message = '(' + '''>>>.* \d\d/\d\d/\d\d\d\d\s+\d\d:\d\d(?::\d\d)?\s*>>>''' + ')'
    text.gsub!(/^(#{multiline_original_message}\n.*)$/m, replacement)

    # On Thu, Nov 28, 2013 at 9:08 AM, A User
    # <[1]request-7-skm40s2ls@xxx.xxxx> wrote:
    text.gsub!(/^( On [^\n]+\n\s*\<[^>\n]+\> (wrote|said):\s*\n.*)$/m, replacement)

    # Single line sections
    text.gsub!(/^(>.*\n)/, replacement)
    text.gsub!(/^(On .+ (wrote|said):\n)/, replacement)

    ['-', '_', '*', '#'].each do |scorechar|
      score = /(?:[#{scorechar}]\s*){8,}/
      text.sub!(/(Disclaimer\s+)?  # appears just before
                        (
                            \s*#{score}\n(?:(?!#{score}\n).)*? # top line
                            (disclaimer:\n|confidential|received\sthis\semail\sin\serror|virus|intended\s+recipient|monitored\s+centrally|intended\s+(for\s+|only\s+for\s+use\s+by\s+)the\s+addressee|routinely\s+monitored|MessageLabs|unauthorised\s+use)
                            .*?(?:#{score}|\z) # bottom line OR end of whole string (for ones with no terminator TODO: risky)
                        )
                       /imx, replacement)
    end

    # Special paragraphs
    # http://www.whatdotheyknow.com/request/identity_card_scheme_expenditure
    text.gsub!(/^[^\n]+Government\s+Secure\s+Intranet\s+virus\s+scanning
                    .*?
                    virus\sfree\.
                    /imx, replacement)
    text.gsub!(/^Communications\s+via\s+the\s+GSi\s+
                    .*?
                    legal\spurposes\.
                    /imx, replacement)
    # http://www.whatdotheyknow.com/request/net_promoter_value_scores_for_bb
    text.gsub!(/^http:\/\/www.bbc.co.uk
                    .*?
                    Further\s+communication\s+will\s+signify\s+your\s+consent\s+to\s+this\.
                    /imx, replacement)


    # To end of message sections
    # http://www.whatdotheyknow.com/request/123/response/192
    # http://www.whatdotheyknow.com/request/235/response/513
    # http://www.whatdotheyknow.com/request/445/response/743
    original_message =
      '(' + '''----* This is a copy of the message, including all the headers. ----*''' +
      '|' + '''----*\s*Original Message\s*----*''' +
      '|' + '''----*\s*Forwarded message.+----*''' +
      '|' + '''----*\s*Forwarded by.+----*''' +
      ')'
    # Could have a ^ at start here, but see messed up formatting here:
    # http://www.whatdotheyknow.com/request/refuse_and_recycling_collection#incoming-842
    text.gsub!(/(#{original_message}\n.*)$/mi, replacement)


    # Some silly Microsoft XML gets into parts marked as plain text.
    # e.g. http://www.whatdotheyknow.com/request/are_traffic_wardens_paid_commiss#incoming-401
    # Don't replace with "replacement" as it's pretty messy
    text.gsub!(/<\?xml:namespace[^>]*\/>/, " ")

    return text
  end

  # Removes anything cached about the object in the database, and saves
  def clear_in_database_caches!
    self.cached_attachment_text_clipped = nil
    self.cached_main_body_text_unfolded = nil
    self.cached_main_body_text_folded = nil
    self.save!
  end

  # Internal function to cache two sorts of main body text.
  # Cached as loading raw_email can be quite huge, and need this for just
  # search results
  def _cache_main_body_text
    text = self.get_main_body_text_internal
    # Strip the uudecode parts from main text
    # - this also effectively does a .dup as well, so text mods don't alter original
    text = text.split(/^begin.+^`\n^end\n/m).join(" ")

    if text.size > 1000000 # 1 MB ish
      raise "main body text more than 1 MB, need to implement clipping like for attachment text, or there is some other MIME decoding problem or similar"
    end

    # apply masks for this message
    text = apply_masks(text, 'text/html')

    # Remove existing quoted sections
    folded_quoted_text = self.remove_lotus_quoting(text, 'FOLDED_QUOTED_SECTION')
    folded_quoted_text = IncomingMessage.remove_quoted_sections(folded_quoted_text, "FOLDED_QUOTED_SECTION")

    self.cached_main_body_text_unfolded = text.delete("\0")
    self.cached_main_body_text_folded = folded_quoted_text.delete("\0")
    self.save!
  end
  # Returns body text from main text part of email, converted to UTF-8, with uudecode removed,
  # emails and privacy sensitive things remove, censored, and folded to remove excess quoted text
  # (marked with FOLDED_QUOTED_SECTION)
  # TODO: returns a .dup of the text, so calling functions can in place modify it
  def get_main_body_text_folded
    if self.cached_main_body_text_folded.nil?
      self._cache_main_body_text
    end
    return self.cached_main_body_text_folded
  end
  def get_main_body_text_unfolded
    if self.cached_main_body_text_unfolded.nil?
      self._cache_main_body_text
    end
    return self.cached_main_body_text_unfolded
  end
  # Returns body text from main text part of email, converted to UTF-8
  def get_main_body_text_internal
    parse_raw_email!
    main_part = get_main_body_text_part
    return _convert_part_body_to_text(main_part)
  end

  # Given a main text part, converts it to text
  def _convert_part_body_to_text(part)
    if part.nil?
      text = "[ Email has no body, please see attachments ]"
    else
      # whatever kind of attachment it is, get the UTF-8 encoded text
      text = part.body_as_text.string
      if part.content_type == 'text/html'
        # e.g. http://www.whatdotheyknow.com/request/35/response/177
        # TODO: This is a bit of a hack as it is calling a
        # convert to text routine.  Could instead call a
        # sanitize HTML one.
        text = MailHandler.get_attachment_text_one_file(part.content_type, text, "UTF-8")
      end
    end

    # Add an annotation if the text had to be scrubbed
    if part && part.body_as_text.scrubbed?
      text += _("\n\n[ {{site_name}} note: The above text was badly encoded, and has had strange characters removed. ]",
                site_name: site_name)
    end
    # Fix DOS style linefeeds to Unix style ones (or other later regexps won't work)
    text = text.gsub(/\r\n/, "\n")

    # Compress extra spaces down to save space, and to stop regular expressions
    # breaking in strange extreme cases. e.g. for
    # http://www.whatdotheyknow.com/request/spending_on_consultants
    text = text.gsub(/ +/, " ")

    return text
  end

  # Returns part which contains main body text, or nil if there isn't one,
  # from a set of foi_attachments. If the leaves parameter is empty or not
  # supplied, uses its own foi_attachments.
  def get_main_body_text_part(leaves=[])
    leaves = self.foi_attachments if leaves.empty?

    # Find first part which is text/plain or text/html
    # (We have to include HTML, as increasingly there are mail clients that
    # include no text alternative for the main part, and we don't want to
    # instead use the first text attachment
    # e.g. http://www.whatdotheyknow.com/request/list_of_public_authorties)
    leaves.each do |p|
      if p.content_type == 'text/plain' or p.content_type == 'text/html'
        return p
      end
    end

    # Otherwise first part which is any sort of text
    leaves.each do |p|
      if p.content_type.match(/^text/)
        return p
      end
    end

    # ... or if none, consider first part
    p = leaves[0]
    # if it is a known type then don't use it, return no body (nil)
    if !p.nil? && AlaveteliFileTypes.mimetype_to_extension(p.content_type)
      # this is guess of case where there are only attachments, no body text
      # e.g. http://www.whatdotheyknow.com/request/cost_benefit_analysis_for_real_n
      return nil
    end
    # otherwise return it assuming it is text (sometimes you get things
    # like binary/octet-stream, or the like, which are really text - TODO: if
    # you find an example, put URL here - perhaps we should be always returning
    # nil in this case)
    return p
  end

  # Returns attachments that are uuencoded in main body part
  def _uudecode_attachments(text, start_part_number)
    # Find any uudecoded things buried in it, yeuchly
    uus = text.scan(/^begin.+^`\n^end\n/m)
    uus.map.with_index do |uu, index|
      # Decode the string
      content = uu.sub(/\Abegin \d+ [^\n]*\n/, '').unpack('u').first
      # Make attachment type from it, working out filename and mime type
      filename = uu.match(/^begin\s+[0-9]+\s+(.*)$/)[1]
      calc_mime = AlaveteliFileTypes.filename_and_content_to_mimetype(filename, content)
      if calc_mime
        calc_mime = MailHandler.normalise_content_type(calc_mime)
        content_type = calc_mime
      else
        content_type = 'application/octet-stream'
      end
      hexdigest = Digest::MD5.hexdigest(content)
      attachment = foi_attachments.find_or_initialize_by(hexdigest: hexdigest)
      attachment.attributes = {
        filename: filename,
        content_type: content_type,
        body: content,
        url_part_number: start_part_number + index + 1
      }
      attachment
    end
  end

  def get_attachments_for_display
    parse_raw_email!
    # return what user would consider attachments, i.e. not the main body
    main_part = get_main_body_text_part
    attachments = []
    for attachment in self.foi_attachments
      attachments << attachment if attachment != main_part
    end
    return attachments
  end

  def extract_attachments!
    extract_attachments
    save!
  end

  def extract_attachments
    _mail = raw_email.mail!
    attachment_attributes = MailHandler.get_attachment_attributes(_mail)
    attachment_attributes = attachment_attributes.inject({}) do |memo, attrs|
      memo[attrs[:hexdigest]] = attrs
      memo
    end

    attachments = attachment_attributes.map do |hexdigest, attrs|
      attachment = foi_attachments.find_or_initialize_by(hexdigest: hexdigest)
      attachment.attributes = attrs
      attachment
    end

    # Get the main body part from the set of attachments not from the
    # foi_attachments association - some of the total set of foi_attachments may
    # now be obsolete. Sometimes (e.g. when parsing mail from Apple Mail) we can
    # end up with less attachments because the hexdigest of an attachment is
    # identical.
    main_part = get_main_body_text_part(attachments)

    # We don't use get_main_body_text_internal, as we want to avoid charset
    # conversions, since _uudecode_attachments needs to deal with those.
    # e.g. for https://secure.mysociety.org/admin/foi/request/show_raw_email/24550
    if main_part
      c = _mail.count_first_uudecode_count
      attachments += _uudecode_attachments(main_part.body, c)
    end

    # Purge old attachments that have been rebuilt with a new hexdigest
    (foi_attachments - attachments).each(&:mark_for_destruction)
  end

  # Returns body text as HTML with quotes flattened, and emails removed.
  def get_body_for_html_display(collapse_quoted_sections = true)
    # Find the body text and remove emails for privacy/anti-spam reasons
    text = get_main_body_text_unfolded
    folded_quoted_text = get_main_body_text_folded

    # Remove quoted sections, adding HTML. TODO: The FOLDED_QUOTED_SECTION is
    # a nasty hack so we can escape other HTML before adding the unfold
    # links, without escaping them. Rather than using some proper parser
    # making a tree structure (I don't know of one that is to hand, that
    # works well in this kind of situation, such as with regexps).
    if collapse_quoted_sections
      text = folded_quoted_text
    end
    text = MySociety::Format.simplify_angle_bracketed_urls(text)
    text = CGI.escapeHTML(text)
    text = MySociety::Format.make_clickable(text, :contract => 1)

    # add a helpful link to email addresses and mobile numbers removed
    # by apply_masks
    email_pattern = Regexp.escape(_("email address"))
    mobile_pattern = Regexp.escape(_("mobile number"))
    text.gsub!(/\[(#{email_pattern}|#{mobile_pattern})\]/,
               '[<a href="/help/officers#mobiles">\1</a>]')

    if collapse_quoted_sections
      text = text.gsub(/(\s*FOLDED_QUOTED_SECTION\s*)+/m, "FOLDED_QUOTED_SECTION")
      text.strip!
      # if there is nothing but quoted stuff, then show the subject
      if text == "FOLDED_QUOTED_SECTION"
        text = "[Subject only] " + CGI.escapeHTML(self.subject || '') + text
      end
      # and display link for quoted stuff
      text = text.gsub(/FOLDED_QUOTED_SECTION/, "\n\n" + '<span class="unfold_link"><a href="?unfold=1#incoming-'+self.id.to_s+'">'+_("show quoted sections")+'</a></span>' + "\n\n")
    else
      if folded_quoted_text.include?('FOLDED_QUOTED_SECTION')
        text = text + "\n\n" + '<span class="unfold_link"><a href="?#incoming-'+self.id.to_s+'">'+_("hide quoted sections")+'</a></span>'
      end
    end
    text.strip!

    text = ActionController::Base.helpers.simple_format(text)
    text.html_safe
  end


  # Returns text of email for using in quoted section when replying
  def get_body_for_quoting
    # Get the body text with emails and quoted sections removed
    text = get_main_body_text_folded.dup
    text.gsub!("FOLDED_QUOTED_SECTION", " ")
    text.strip!
    raise "internal error" if text.nil?
    return text
  end

  # Returns text version of attachment text
  def get_attachment_text_full
    text = self._get_attachment_text_internal
    text = apply_masks(text, 'text/html')

    # This can be useful for memory debugging
    #STDOUT.puts 'xxx '+ MySociety::DebugHelpers::allocated_string_size_around_gc

    # Save clipped version for snippets
    if self.cached_attachment_text_clipped.nil?
      clipped = text.mb_chars[0..MAX_ATTACHMENT_TEXT_CLIPPED].delete("\0")
      self.cached_attachment_text_clipped = clipped
      save!
    end

    return text
  end
  # Returns a version reduced to a sensible maximum size - this
  # is for performance reasons when showing snippets in search results.
  def get_attachment_text_clipped
    if self.cached_attachment_text_clipped.nil?
      # As side effect, get_attachment_text_full makes snippet text
      attachment_text = self.get_attachment_text_full
      raise "internal error" if self.cached_attachment_text_clipped.nil?
    end

    return self.cached_attachment_text_clipped
  end

  def _extract_text
    # Extract text from each attachment
    self.get_attachments_for_display.reduce('') { |memo, attachment|
      memo += MailHandler.get_attachment_text_one_file(attachment.content_type,
                                                       attachment.default_body,
                                                       attachment.charset)
    }
  end

  def _get_attachment_text_internal
    convert_string_to_utf8(_extract_text, 'UTF-8').string
  end

  # Returns text for indexing
  def get_text_for_indexing_full
    return get_body_for_quoting + "\n\n" + get_attachment_text_full
  end
  # Used for excerpts in search results, when loading full text would be too slow
  def get_text_for_indexing_clipped
    return get_body_for_quoting + "\n\n" + get_attachment_text_clipped
  end

  # Has message arrived "recently"?
  def recently_arrived
    (Time.zone.now - self.created_at) <= 3.days
  end

  # Search all info requests for
  def self.find_all_unknown_mime_types
    IncomingMessage.find_each do |incoming_message|
      for attachment in incoming_message.get_attachments_for_display
        raise "internal error incoming_message " + incoming_message.id.to_s if attachment.content_type.nil?
        if AlaveteliFileTypes.mimetype_to_extension(attachment.content_type).nil?
          $stderr.puts "Unknown type for /request/" + incoming_message.info_request.id.to_s + "#incoming-"+incoming_message.id.to_s
          $stderr.puts " " + attachment.filename.to_s + " " + attachment.content_type.to_s
        end
      end
    end

    return nil
  end

  # Returns space separated list of file extensions of attachments to this message. Defaults to
  # the normal extension for known mime type, otherwise uses other extensions.
  def get_present_file_extensions
    ret = {}
    for attachment in self.get_attachments_for_display
      ext = AlaveteliFileTypes.mimetype_to_extension(attachment.content_type)
      ext = File.extname(attachment.filename).gsub(/^[.]/, "") if ext.nil? && !attachment.filename.nil?
      ret[ext] = 1 if !ext.nil?
    end
    return ret.keys.join(" ")
  end

  def refusals
    legislation_references.select(&:refusal?).map(&:parent).uniq(&:to_s)
  end

  def refusals?
    refusals.any?
  end

  private

  def legislation_references
    legislation.find_references(get_main_body_text_folded)
  end
end
