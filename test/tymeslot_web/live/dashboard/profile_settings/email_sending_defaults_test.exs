defmodule TymeslotWeb.Dashboard.ProfileSettings.EmailSendingDefaultsTest do
  @moduledoc "Exercises first-time SMTP sender suggestions without sending email."

  use TymeslotWeb.LiveCase, async: false

  @moduletag :emails
  @moduletag :live

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.EmailSendingTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.EmailSending
  alias Tymeslot.Repo

  @attrs %{
    "host" => "smtp.example.com",
    "security" => "starttls",
    "username" => "sender@example.com",
    "password" => "sender-defaults-password-secret",
    "from_address" => "",
    "from_name" => "Profile Sender"
  }

  setup :setup_dashboard_user

  setup context do
    with_config(:tymeslot, user_smtp_enabled: true)
    profile = context.profile |> Changeset.change(full_name: "Profile Sender") |> Repo.update!()
    %{profile: profile}
  end

  test "first setup starts with the profile's display name and no guessed email", context do
    {:ok, view, html} = open_smtp_settings(context.conn)
    assert has_element?(view, "#smtp-from-name[value='Profile Sender']")
    assert has_element?(view, "#smtp-from-address[value='']")
    assert has_element?(view, "input[name='smtp[username]'][value='']")
    assert has_element?(view, "input[name='smtp[password]'][value='']")
    refute html =~ @attrs["password"]
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
  end

  test "a missing display name stays blank instead of falling back to the account email",
       context do
    context.profile |> Changeset.change(full_name: nil) |> Repo.update!()
    context.user |> Changeset.change(name: nil) |> Repo.update!()
    {:ok, view, _html} = open_smtp_settings(context.conn)
    assert has_element?(view, "#smtp-from-name[value='']")
    assert has_element?(view, "#smtp-from-address[value='']")
  end

  test "valid email usernames suggest and update the From address without retaining credentials",
       context do
    {:ok, view, html} = open_smtp_settings(context.conn)
    input_ids = credential_ids(html)
    assert length(input_ids) == 2

    for username <- ["sender@example.com", "  updated@example.com  "] do
      html = validate(view, Map.put(@attrs, "username", username), "username")
      assert has_element?(view, "#smtp-from-address[value='#{String.trim(username)}']")
      assert has_element?(view, "#smtp-from-name[value='Profile Sender']")
      assert has_element?(view, "input[name='smtp[username]'][value='']")
      assert has_element?(view, "input[name='smtp[password]'][value='']")
      assert credential_ids(html) == input_ids
      refute html =~ @attrs["password"]
      refute :erlang.term_to_binary(:sys.get_state(view.pid)) =~ @attrs["password"]
    end

    assert {:error, :not_found} = EmailSending.get_settings(context.user)
  end

  test "non-email usernames never become a From address or enter retained form state", context do
    {:ok, view, _html} = open_smtp_settings(context.conn)
    validate(view, @attrs, "username")
    assert has_element?(view, "#smtp-from-address[value='sender@example.com']")

    for username <- ["non-email-smtp-account", "incomplete@", "sender@localhost"] do
      html = validate(view, Map.put(@attrs, "username", username), "username")
      assert has_element?(view, "#smtp-from-address[value='']")
      refute html =~ username
      refute :erlang.term_to_binary(:sys.get_state(view.pid)) =~ username
      refute :erlang.term_to_binary(:sys.get_state(view.pid)) =~ @attrs["password"]
    end

    assert {:error, :not_found} = EmailSending.get_settings(context.user)
  end

  test "malformed username change payloads cannot bypass the form boundary", context do
    {:ok, view, _html} = open_smtp_settings(context.conn)

    for params <- [nil, "invalid", ["sender@example.com"], %{"username" => %{}}] do
      view
      |> with_target("#email-sending-settings")
      |> render_change("validate_smtp", %{"smtp" => params, "_target" => ["smtp", "username"]})

      assert has_element?(view, "#smtp-from-address[value='']")
      assert has_element?(view, "input[name='smtp[username]'][value='']")
      assert has_element?(view, "input[name='smtp[password]'][value='']")
    end

    assert {:error, :not_found} = EmailSending.get_settings(context.user)
  end

  test "editing or clearing From address stops suggestions and preserves a custom display name",
       context do
    {:ok, view, _html} = open_smtp_settings(context.conn)
    validate(view, @attrs, "username")

    custom =
      Map.merge(@attrs, %{"from_address" => "bookings@example.com", "from_name" => "My Brand"})

    validate(view, custom, "from_address")
    validate(view, custom, "from_name")
    validate(view, Map.put(custom, "username", "different@example.com"), "username")
    assert has_element?(view, "#smtp-from-address[value='bookings@example.com']")
    assert has_element?(view, "#smtp-from-name[value='My Brand']")

    cleared = Map.put(custom, "from_address", "")
    validate(view, cleared, "from_address")
    validate(view, Map.put(cleared, "username", "another@example.com"), "username")
    assert has_element?(view, "#smtp-from-address[value='']")
    assert has_element?(view, "#smtp-from-name[value='My Brand']")

    view
    |> with_target("#email-sending-settings")
    |> render_submit("test_and_save_smtp", %{
      "smtp" => Map.merge(cleared, %{"username" => "another@example.com", "host" => "127.0.0.1"})
    })

    assert has_element?(view, "#smtp-from-address[value=''][aria-invalid='true']")
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
  end

  test "a username suggestion clears a previous From-required error", context do
    {:ok, view, _html} = open_smtp_settings(context.conn)

    view
    |> with_target("#email-sending-settings")
    |> render_submit("test_and_save_smtp", %{
      "smtp" => Map.merge(@attrs, %{"host" => "127.0.0.1", "username" => "smtp-account"})
    })

    assert has_element?(view, "#smtp-from-address[aria-invalid='true']")
    validate(view, @attrs, "username")
    assert has_element?(view, "#smtp-from-address[value='sender@example.com']")
    refute has_element?(view, "#smtp-from-address[aria-invalid='true']")
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
  end

  test "new setup resets discarded edits and uses the latest profile name when reopened",
       context do
    {:ok, view, _html} = open_smtp_settings(context.conn)
    validate(view, @attrs, "username")
    view |> element("#use-custom-smtp") |> render_click()
    refute has_element?(view, "#user-smtp-form")

    view
    |> form("#display-name-form", %{"full_name" => "Updated Profile Sender"})
    |> render_change()

    view |> element("#use-custom-smtp") |> render_click()
    assert has_element?(view, "#smtp-from-name[value='Updated Profile Sender']")
    assert has_element?(view, "#smtp-from-address[value='']")

    attrs = Map.put(@attrs, "from_name", "Updated Profile Sender")
    validate(view, attrs, "username")
    assert has_element?(view, "#smtp-from-address[value='sender@example.com']")
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
  end

  test "a direct first submission supplies the From suggestion before validating", context do
    {:ok, view, _html} = open_smtp_settings(context.conn)

    html =
      view
      |> with_target("#email-sending-settings")
      |> render_submit("test_and_save_smtp", %{
        "smtp" => Map.put(@attrs, "host", "127.0.0.1")
      })

    assert has_element?(view, "#smtp-from-address[value='sender@example.com']")
    assert has_element?(view, "#smtp-host[aria-invalid='true']")
    assert has_element?(view, "input[name='smtp[username]'][value='']")
    assert has_element?(view, "input[name='smtp[password]'][value='']")
    refute html =~ @attrs["password"]
    assert {:error, :not_found} = EmailSending.get_settings(context.user)
  end

  test "disabled saved identities retain their explicit From values when setup opens", context do
    assert_saved_values_unchanged(context, false)
  end

  test "enabled saved identities retain their explicit From values during username edits",
       context do
    assert_saved_values_unchanged(context, true)
  end

  # Saved identities are authoritative even when their From address differs
  # from both the account email and a newly entered SMTP username.
  @spec assert_saved_values_unchanged(map(), boolean()) :: :ok
  defp assert_saved_values_unchanged(context, enabled) do
    attrs =
      Map.merge(@attrs, %{
        "from_address" => "saved-brand@example.com",
        "from_name" => "Saved Brand"
      })

    original = saved_smtp_settings(context.user, attrs, enabled: enabled)
    {:ok, view, _html} = open_smtp_settings(context.conn)
    assert has_element?(view, "#smtp-from-name[value='Saved Brand']")
    assert has_element?(view, "#smtp-from-address[value='saved-brand@example.com']")
    validate(view, Map.put(attrs, "username", "replacement@example.com"), "username")
    assert has_element?(view, "#smtp-from-name[value='Saved Brand']")
    assert has_element?(view, "#smtp-from-address[value='saved-brand@example.com']")
    assert Repo.reload!(original) == original
    :ok
  end

  # Explicit targets mirror the input changed in the browser without putting
  # credential values into the component's persistent assigns.
  @spec validate(Phoenix.LiveViewTest.View.t(), map(), String.t()) :: String.t()
  defp validate(view, attrs, field) do
    view
    |> with_target("#email-sending-settings")
    |> render_change("validate_smtp", %{"smtp" => attrs, "_target" => ["smtp", field]})
  end

  @spec credential_ids(String.t()) :: [String.t()]
  defp credential_ids(html) do
    {:ok, document} = Floki.parse_document(html)
    document |> Floki.find("input[data-smtp-credential]") |> Floki.attribute("id")
  end
end
