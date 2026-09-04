defmodule Tymeslot.Emails.BrandingTest do
  use Tymeslot.DataCase, async: false

  @moduletag :emails

  import ExUnit.CaptureLog
  import Tymeslot.AppSettingsEnvHelpers

  alias Swoosh.Email
  alias Tymeslot.AppSettings
  alias Tymeslot.Emails.Branding
  alias Tymeslot.Emails.Shared.Layouts
  alias Tymeslot.Emails.Shared.MjmlEmail
  alias Tymeslot.Emails.Shared.Styles.BrandPalette
  alias Tymeslot.Emails.Shared.TemplateHelper
  alias Tymeslot.Utils.Colour

  setup :restore_app_settings_env

  # Cleared before as well as after: another module's logo upload (the admin
  # branding LiveView test) removes its file but leaves the directory behind,
  # and the "stores nothing" assertion below reads that leftover as a write.
  setup do
    clear_branding_dir()
    on_exit(&clear_branding_dir/0)
    :ok
  end

  defp clear_branding_dir do
    upload_dir()
    |> Path.join("branding")
    |> File.rm_rf()
  end

  # A 1x1 PNG, the smallest thing ExImageInfo will recognise as one.
  defp png_bytes do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )
  end

  defp upload_dir, do: Application.get_env(:tymeslot, :upload_directory)

  # `Branding.store_logo/1` takes a source path, matching the upload
  # temp-file it is fed in production, so tests write bytes to a temp file
  # first rather than handing bytes directly.
  defp temp_file(bytes) do
    path = Path.join(System.tmp_dir!(), "branding-test-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    path
  end

  defp png_path, do: temp_file(png_bytes())

  describe "brand_name/0" do
    test "defaults to Tymeslot when the instance has not set one" do
      assert Branding.brand_name() == "Tymeslot"
    end

    test "returns the configured name" do
      {:ok, _settings} = AppSettings.update(%{email_brand_name: "Beaver Dental"})

      assert Branding.brand_name() == "Beaver Dental"
    end

    test "falls back to Tymeslot when the override is cleared" do
      {:ok, _settings} = AppSettings.update(%{email_brand_name: "Beaver Dental"})
      {:ok, _settings} = AppSettings.update(%{email_brand_name: nil})

      assert Branding.brand_name() == "Tymeslot"
    end
  end

  describe "stock_accent/0" do
    test "always returns the shipped turquoise, ignoring any configured accent" do
      {:ok, _settings} = AppSettings.update(%{email_brand_accent: "#7c3aed"})

      assert Branding.stock_accent() == "#14b8a6"
    end
  end

  describe "stock_family/0" do
    test "returns the four hand-tuned turquoise tokens" do
      assert %{accent: "#14b8a6", deep: "#0d786c", ink: "#0f5954", tint: "#e1f7f3"} =
               Branding.stock_family()
    end

    test "the deep token clears the same 4.5:1 band-text floor derived families are clamped to" do
      assert Colour.contrast_ratio(BrandPalette.band_text(), Branding.stock_family().deep) >= 4.5
    end
  end

  describe "normalise_accent/1" do
    test "normalises a valid hex colour" do
      assert Branding.normalise_accent("#7C3AED") == "#7c3aed"
    end

    test "returns nil for an invalid colour" do
      assert Branding.normalise_accent("nope") == nil
    end
  end

  describe "accent_preview/1" do
    test "reports the normalised hex and the white-on-accent contrast ratio" do
      # Deliberately not clamped: this is the number the admin UI surfaces so
      # an admin can decide about their own brand colour.
      assert %{hex: "#f5d90a", contrast: contrast, low_contrast?: true} =
               Branding.accent_preview("#f5d90a")

      assert contrast < 3.0

      assert %{hex: "#0f172a", low_contrast?: false} = Branding.accent_preview("#0f172a")
    end

    test "warns on a mid-range ratio that clears the large-text bar but not the button's" do
      # ≈3.74:1 against white — above the old (wrong) 3.0 large-text gate this
      # module used to check, but below the 4.5:1 that applies to the button's
      # 16px bold label, which is not large text.
      assert %{hex: "#0d9488", contrast: contrast, low_contrast?: true} =
               Branding.accent_preview("#0d9488")

      assert contrast > 3.0 and contrast < 4.5
    end

    test "returns nil for an invalid colour" do
      assert Branding.accent_preview("nope") == nil
    end

    test "returns nil for nil" do
      assert Branding.accent_preview(nil) == nil
    end
  end

  describe "store_logo/1" do
    test "writes the file, records a relative path, and reports it" do
      assert {:ok, relative} = Branding.store_logo(png_path())

      assert String.starts_with?(relative, "branding/")
      assert String.ends_with?(relative, ".png")
      assert File.exists?(Path.join(upload_dir(), relative))
      assert AppSettings.get(:email_logo_path) == relative
    end

    test "rejects bytes that are not really a PNG, and stores nothing" do
      assert {:error, :not_a_png} =
               Branding.store_logo(temp_file("<svg><script>alert(1)</script></svg>"))

      assert AppSettings.get(:email_logo_path) == nil
      refute File.exists?(Path.join(upload_dir(), "branding"))
    end

    test "rejects a JPEG even though it is a valid image" do
      # The email attaches with a PNG content type, so anything else would be
      # mislabelled on the wire.
      jpeg = <<0xFF, 0xD8, 0xFF, 0xE0>> <> :binary.copy(<<0>>, 128)

      assert {:error, :not_a_png} = Branding.store_logo(temp_file(jpeg))
    end

    test "deletes the previous logo when a replacement is stored" do
      {:ok, first} = Branding.store_logo(png_path())
      {:ok, second} = Branding.store_logo(png_path())

      refute first == second
      refute File.exists?(Path.join(upload_dir(), first))
      assert File.exists?(Path.join(upload_dir(), second))
    end
  end

  describe "remove_logo/0" do
    test "clears the setting and deletes the file" do
      {:ok, relative} = Branding.store_logo(png_path())

      assert :ok = Branding.remove_logo()

      assert AppSettings.get(:email_logo_path) == nil
      refute File.exists?(Path.join(upload_dir(), relative))
    end

    test "is a no-op when no logo is configured" do
      assert :ok = Branding.remove_logo()
    end
  end

  describe "custom_logo_path/0" do
    test "is nil when no logo is configured" do
      assert Branding.custom_logo_path() == nil
    end

    test "is nil when the configured file has been deleted from disk" do
      {:ok, relative} = Branding.store_logo(png_path())
      File.rm!(Path.join(upload_dir(), relative))

      assert Branding.custom_logo_path() == nil
    end
  end

  describe "logo_bytes/0" do
    test "returns the stock logo when no custom logo is configured" do
      assert {:ok, bytes} = Branding.logo_bytes()
      assert bytes == File.read!(Branding.stock_logo_path())
    end

    test "returns the custom logo when one is configured" do
      {:ok, _relative} = Branding.store_logo(png_path())

      assert {:ok, bytes} = Branding.logo_bytes()
      assert bytes == png_bytes()
    end

    test "falls back to the stock logo when the configured file vanished" do
      {:ok, relative} = Branding.store_logo(png_path())
      File.rm!(Path.join(upload_dir(), relative))

      assert {:ok, bytes} = Branding.logo_bytes()
      assert bytes == File.read!(Branding.stock_logo_path())
    end

    test "logs the missing configured logo once, not once per call" do
      {:ok, relative} = Branding.store_logo(png_path())
      File.rm!(Path.join(upload_dir(), relative))

      log =
        capture_log(fn ->
          for _attempt <- 1..5, do: Branding.logo_bytes()
        end)

      assert Enum.count(String.split(log, "\n"), &(&1 =~ "Configured email logo is missing")) ==
               1
    end
  end

  describe "logo_url/0" do
    test "is nil without a configured logo" do
      assert Branding.logo_url() == nil
    end

    test "points at the path the endpoint serves uploads from" do
      {:ok, relative} = Branding.store_logo(png_path())

      assert Branding.logo_url() == "/uploads/" <> relative
    end

    test "is nil when the configured file has been deleted from disk" do
      {:ok, relative} = Branding.store_logo(png_path())
      File.rm!(Path.join(upload_dir(), relative))

      assert Branding.logo_url() == nil
    end
  end

  describe "path validation" do
    test "the schema refuses a stored path that would escape the upload directory" do
      assert {:error, changeset} =
               AppSettings.update(%{email_logo_path: "../../etc/passwd"})

      assert %{email_logo_path: [_message]} = errors_on(changeset)
    end

    test "the schema refuses an absolute stored path" do
      assert {:error, changeset} = AppSettings.update(%{email_logo_path: "/etc/passwd"})

      assert %{email_logo_path: [_message]} = errors_on(changeset)
    end
  end

  describe "rendered into an email" do
    defp transactional_mjml do
      Layouts.transactional_layout(
        "<mj-section><mj-column><mj-text>Body</mj-text></mj-column></mj-section>",
        name: "Jane Smith",
        intent: :confirmed,
        eyebrow: "Confirmed"
      )
    end

    test "the stock branding renders the Tymeslot name and turquoise accent" do
      mjml = transactional_mjml()

      assert mjml =~ ~s(alt="Tymeslot")
      assert mjml =~ "Jane Smith via Tymeslot"
      assert mjml =~ "#0d786c"
    end

    test "a configured brand name replaces it in the alt text and preview line" do
      {:ok, _settings} = AppSettings.update(%{email_brand_name: "Beaver Dental"})

      mjml = transactional_mjml()

      assert mjml =~ ~s(alt="Beaver Dental")
      assert mjml =~ "Jane Smith via Beaver Dental"
      refute mjml =~ "via Tymeslot"
    end

    test "a configured accent reaches the rendered stage band" do
      {:ok, _settings} = AppSettings.update(%{email_brand_accent: "#7c3aed"})

      mjml = transactional_mjml()
      %{deep: deep} = BrandPalette.derive("#7c3aed")

      assert mjml =~ deep
      refute mjml =~ Branding.stock_family().deep
    end

    test "the footer attribution stays put whatever the branding" do
      {:ok, _settings} =
        AppSettings.update(%{email_brand_name: "Beaver Dental", email_brand_accent: "#7c3aed"})

      assert transactional_mjml() =~ "Tymeslot</a>"
    end

    # Regression: the organiser strip is built by `TemplateHelper`, not by the
    # layout, so it carried its own hardcoded "Tymeslot" fallback. Every
    # appointment email goes through that path, which meant the strip stayed
    # unbranded no matter what the instance had configured.
    test "the organiser strip title follows the brand name" do
      {:ok, _settings} = AppSettings.update(%{email_brand_name: "Beaver Dental"})

      details =
        TemplateHelper.build_organizer_details(
          %{
            organizer_name: "Jane Smith",
            organizer_email: "jane@example.com",
            organizer_title: nil,
            organizer_avatar_url: nil
          },
          intent: :confirmed,
          eyebrow: "Confirmed"
        )

      assert details.title == "Beaver Dental"
    end

    test "an explicit organiser title still wins over the brand name" do
      {:ok, _settings} = AppSettings.update(%{email_brand_name: "Beaver Dental"})

      details =
        TemplateHelper.build_organizer_details(
          %{
            organizer_name: "Jane Smith",
            organizer_email: "jane@example.com",
            organizer_title: "Principal Dentist",
            organizer_avatar_url: nil
          },
          intent: :confirmed,
          eyebrow: "Confirmed"
        )

      assert details.title == "Principal Dentist"
    end

    test "a brand name with markup in it is escaped before it reaches the HTML" do
      {:ok, _settings} = AppSettings.update(%{email_brand_name: ~s(Ben & Co "Dental")})

      mjml = transactional_mjml()

      refute mjml =~ ~s(alt="Ben & Co "Dental")
      assert mjml =~ "Ben &amp; Co"
    end
  end

  describe "attached to an email" do
    test "the inline attachment carries the custom logo bytes" do
      {:ok, _relative} = Branding.store_logo(png_path())

      email = MjmlEmail.attach_logo(Email.new())

      assert [attachment] = email.attachments
      assert attachment.content_type == "image/png"
      assert attachment.cid == MjmlEmail.logo_cid()
      assert attachment.filename == MjmlEmail.logo_cid()
      assert attachment.data == png_bytes()
    end

    test "the attachment falls back to the stock logo with no custom logo set" do
      email = MjmlEmail.attach_logo(Email.new())

      assert [attachment] = email.attachments
      assert attachment.data == File.read!(Branding.stock_logo_path())
    end
  end
end
