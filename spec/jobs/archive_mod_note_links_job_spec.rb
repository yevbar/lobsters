# typed: false

require "rails_helper"

RSpec.describe ArchiveModNoteLinksJob, type: :job do
  let(:user) { create(:user) }
  let(:moderator) { create(:user, :moderator) }

  def create_mod_note(note_text)
    ModNote.create!(
      user: user,
      moderator: moderator,
      note: note_text
    )
  end

  describe "#extract_urls" do
    subject { described_class.new }

    it "extracts http and https URLs" do
      urls = subject.send(:extract_urls, "Check https://example.com and http://test.org")
      expect(urls).to contain_exactly("https://example.com", "http://test.org")
    end

    it "returns empty array for notes with no URLs" do
      urls = subject.send(:extract_urls, "Just a plain note about this user")
      expect(urls).to be_empty
    end

    it "deduplicates URLs" do
      urls = subject.send(:extract_urls, "Visit https://example.com twice: https://example.com")
      expect(urls).to eq(["https://example.com"])
    end

    it "ignores non-http schemes" do
      urls = subject.send(:extract_urls, "Email mailto:foo@bar.com and ftp://files.example.com")
      expect(urls).to be_empty
    end

    it "strips trailing punctuation from markdown links" do
      urls = subject.send(:extract_urls, "See [this page](https://example.com/path) for details")
      expect(urls).to eq(["https://example.com/path"])
    end

    it "strips trailing punctuation from prose" do
      urls = subject.send(:extract_urls, "Visited https://example.com.")
      expect(urls).to eq(["https://example.com"])
    end

    it "handles URLs with query parameters" do
      urls = subject.send(:extract_urls, "See https://example.com/page?q=1&lang=en for info")
      expect(urls).to eq(["https://example.com/page?q=1&lang=en"])
    end
  end

  describe "#perform" do
    let(:mock_sponge) { instance_double(Sponge) }
    let(:mock_response) { instance_double(Net::HTTPResponse, code: "200") }

    before do
      allow(Sponge).to receive(:new).and_return(mock_sponge)
      allow(mock_sponge).to receive(:timeout=)
      allow(mock_sponge).to receive(:ssl_verify=)
      allow(mock_sponge).to receive(:fetch).and_return(mock_response)
      allow_any_instance_of(described_class).to receive(:sleep) # don't actually sleep in tests
    end

    it "archives URLs found in the mod note" do
      mod_note = create_mod_note("Check https://example.com for context")

      expect(mock_sponge).to receive(:fetch).with(
        "https://web.archive.org/save/https://example.com",
        :get, {}, nil,
        hash_including("User-agent"),
        3
      ).and_return(mock_response)

      described_class.new.perform(mod_note)
    end

    it "archives multiple URLs with sleep between them" do
      mod_note = create_mod_note("See https://example.com and http://test.org")

      expect(mock_sponge).to receive(:fetch).twice.and_return(mock_response)
      expect_any_instance_of(described_class).to receive(:sleep).with(5).once

      described_class.new.perform(mod_note)
    end

    it "does nothing for notes without URLs" do
      mod_note = create_mod_note("Just a plain note")

      expect(mock_sponge).not_to receive(:fetch)

      described_class.new.perform(mod_note)
    end

    it "continues processing after a network error" do
      mod_note = create_mod_note("See https://fail.example.com and https://success.example.com")

      call_count = 0
      allow(mock_sponge).to receive(:fetch) do |url, *|
        call_count += 1
        if call_count == 1
          raise Net::ReadTimeout, "read timeout"
        end
        mock_response
      end

      expect { described_class.new.perform(mod_note) }.not_to raise_error
    end

    it "handles DNS failures gracefully" do
      mod_note = create_mod_note("Check https://nonexistent.example.com")

      allow(mock_sponge).to receive(:fetch).and_raise(DNSError.new("couldn't resolve"))

      expect { described_class.new.perform(mod_note) }.not_to raise_error
    end

    it "handles SSL errors gracefully" do
      mod_note = create_mod_note("Check https://badssl.example.com")

      allow(mock_sponge).to receive(:fetch).and_raise(OpenSSL::SSL::SSLError.new("SSL error"))

      expect { described_class.new.perform(mod_note) }.not_to raise_error
    end

    it "handles nil response from Sponge" do
      mod_note = create_mod_note("Check https://example.com")

      allow(mock_sponge).to receive(:fetch).and_return(nil)

      expect { described_class.new.perform(mod_note) }.not_to raise_error
    end

    it "does not sleep after the last URL" do
      mod_note = create_mod_note("Just https://example.com")

      expect_any_instance_of(described_class).not_to receive(:sleep)

      described_class.new.perform(mod_note)
    end
  end

  describe "job enqueuing" do
    include ActiveJob::TestHelper

    it "is enqueued on the default queue" do
      mod_note = create_mod_note("Check https://example.com")

      assert_enqueued_with(job: described_class, queue: "default") do
        described_class.perform_later(mod_note)
      end
    end
  end
end

