defmodule TymeslotWeb.Dashboard.ProfileSettings.EmailSending.FormInputTest do
  @moduledoc "Tests the boundary between SMTP form input and domain settings."

  use ExUnit.Case, async: true

  @moduletag :emails

  alias Ecto.Changeset
  alias Tymeslot.EmailSending.Settings
  alias Tymeslot.EmailSending.UserSmtpSettingsSchema
  alias TymeslotWeb.Dashboard.ProfileSettings.EmailSending.FormInput

  test "supported security modes determine their ports regardless of submitted port" do
    for {security, port} <- [{"starttls", "587"}, {"implicit_tls", "465"}],
        submitted_port <- [nil, "25", "465", "587", 25, %{"value" => "25"}] do
      assert %{"security" => ^security, "port" => ^port} =
               FormInput.attributes(%{"security" => security, "port" => submitted_port})
    end

    assert FormInput.attributes(%{"security" => "starttls"})["port"] == "587"
    assert FormInput.attributes(%{"security" => "implicit_tls"})["port"] == "465"
    refute "port" in FormInput.fields()
  end

  test "missing and malformed modes remain invalid without a derived port" do
    for security <- [nil, "", "none", "STARTTLS", true, 42, %{}, ["starttls"]] do
      attrs = FormInput.attributes(%{"security" => security, "port" => "587"})
      assert attrs["security"] == security
      refute Map.has_key?(attrs, "port")
    end

    assert FormInput.attributes(%{"port" => "587"}) == %{}
    assert FormInput.attributes(nil) == %{}
    assert FormInput.attributes("starttls") == %{}
  end

  test "credentials pass to validation while lifecycle and ownership fields are discarded" do
    attrs =
      FormInput.attributes(%{
        "security" => "implicit_tls",
        "username" => "smtp-account",
        "password" => "smtp-secret",
        "user_id" => 123,
        "enabled" => true,
        "revision" => 1,
        "tested_revision" => 1
      })

    assert attrs == %{
             "security" => "implicit_tls",
             "port" => "465",
             "username" => "smtp-account",
             "password" => "smtp-secret"
           }
  end

  test "a profile name seeds only the initial identity values" do
    assert FormInput.values(nil, "Profile Name")["from_name"] == "Profile Name"
    assert FormInput.values(nil)["from_name"] == ""

    for name <- ["Custom sender", "", nil] do
      saved = %Settings{from_name: name}
      validated = Changeset.change(%UserSmtpSettingsSchema{}, from_name: name)
      expected = name || ""
      assert FormInput.values(saved, "Profile Name")["from_name"] == expected
      assert FormInput.values(validated, "Profile Name")["from_name"] == expected
    end
  end

  test "an email username can seed From without changing its credentials" do
    attrs = %{"username" => " bookings@example.com ", "password" => "smtp-secret"}
    suggested = FormInput.default_from_address(attrs)
    assert suggested["from_address"] == "bookings@example.com"
    assert suggested["username"] == attrs["username"]
    assert suggested["password"] == attrs["password"]
  end

  test "invalid and non-email usernames cannot become the public From address" do
    for username <- [
          nil,
          "",
          "smtp-account",
          "user@",
          "user@localhost",
          "user@example.invalid",
          "user@example.com\r\nBcc: other@example.com",
          <<255>>,
          String.duplicate("a", 255) <> "@example.com",
          123,
          true,
          %{},
          ["user@example.com"]
        ] do
      assert FormInput.default_from_address(%{"username" => username})["from_address"] == ""
    end
  end
end
