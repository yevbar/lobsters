# typed: false

class ArchiveModNoteLinksJob < ApplicationJob
  queue_as :default

  ARCHIVE_SAVE_URL = "https://web.archive.org/save/"

  # archive.org allows ~15 req/min for the save API; 5s sleep is conservative
  SLEEP_BETWEEN_REQUESTS = 5

  def perform(mod_note)
    urls = extract_urls(mod_note.note)
    return if urls.empty?

    Rails.logger.info "[ArchiveModNoteLinks] Archiving #{urls.length} URL(s) from ModNote #{mod_note.id}"

    urls.each_with_index do |url, i|
      archive_url(url)
      sleep SLEEP_BETWEEN_REQUESTS if i < urls.length - 1
    end
  end

  private

  def extract_urls(text)
    URI.extract(text, %w[http https]).map { |url|
      # URI.extract can grab trailing punctuation from markdown/prose, e.g. ) from [text](url)
      url.sub(/[)\]>,;:!?.]+\z/, "")
    }.uniq
  end

  def archive_url(url)
    sp = Sponge.new
    sp.timeout = 30
    sp.ssl_verify = true

    save_url = "#{ARCHIVE_SAVE_URL}#{url}"
    begin
      response = sp.fetch(save_url, :get, {}, nil, {
        "User-agent" => "#{Rails.application.domain} mod-note-archiver"
      }, 3)

      if response
        Rails.logger.info "[ArchiveModNoteLinks] Saved #{url} (status: #{response.code})"
      else
        Rails.logger.warn "[ArchiveModNoteLinks] No response archiving #{url}"
      end
    rescue BadIPsError, NoIPsError, DNSError, Errno::ECONNREFUSED,
      OpenSSL::SSL::SSLError, TooManyRedirects, Zlib::DataError,
      Net::ReadTimeout, Net::OpenTimeout, SocketError => e
      Rails.logger.warn "[ArchiveModNoteLinks] Error archiving #{url}: #{e.class}: #{e.message}"
    end
  end
end


