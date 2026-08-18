defmodule Tymeslot.Integrations.Calendar.CreationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.Factory
  alias Tymeslot.Integrations.Calendar.Creation
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Profiles.ProfileQueries

  setup :verify_on_exit!

  describe "prepare_attrs/2 — nextcloud" do
    test "returns atom-keyed attrs that satisfy the maybe_discover_calendars/1 guard" do
      # Verifies that the atom-keyed map produced here will match the %{provider: provider}
      # pattern in Discovery.maybe_discover_calendars/1, ensuring the Nextcloud discovery
      # branch is reachable (not dead code).
      params = %{
        "name" => "Test Nextcloud",
        "provider" => "nextcloud",
        "url" => "https://nextcloud.example.com",
        "username" => "alice",
        "password" => "secret",
        "calendar_paths" => ""
      }

      assert {:ok, attrs} = Creation.prepare_attrs(params, 1)

      assert attrs.provider == "nextcloud"
      assert Map.has_key?(attrs, :provider)
      refute Map.has_key?(attrs, "provider")
      assert attrs.base_url == "https://nextcloud.example.com"
      assert attrs.is_active == true
    end
  end

  describe "prepare_attrs/2" do
    test "prepares attributes for CalDAV integration" do
      params = %{
        "name" => "Test CalDAV",
        "provider" => "caldav",
        "url" => "https://caldav.example.com",
        "username" => "testuser",
        "password" => "testpass",
        "calendar_paths" => "/calendars/user/personal"
      }

      assert {:ok, attrs} = Creation.prepare_attrs(params, 1)

      assert attrs.user_id == 1
      assert attrs.name == "Test CalDAV"
      assert attrs.provider == "caldav"
      assert attrs.base_url == "https://caldav.example.com"
      assert attrs.username == "testuser"
      assert attrs.password == "testpass"
      assert attrs.calendar_paths == ["/calendars/user/personal"]
      assert attrs.is_active == true
    end

    test "handles empty calendar paths" do
      params = %{
        "name" => "Test",
        "provider" => "caldav",
        "url" => "https://example.com",
        "username" => "user",
        "password" => "pass",
        "calendar_paths" => ""
      }

      assert {:ok, attrs} = Creation.prepare_attrs(params, 1)
      assert attrs.calendar_paths == []
    end

    test "parses comma-separated calendar paths" do
      params = %{
        "name" => "Test",
        "provider" => "caldav",
        "url" => "https://example.com",
        "username" => "user",
        "password" => "pass",
        "calendar_paths" => "/cal1, /cal2, /cal3"
      }

      assert {:ok, attrs} = Creation.prepare_attrs(params, 1)
      assert length(attrs.calendar_paths) == 3
      assert "/cal1" in attrs.calendar_paths
      assert "/cal2" in attrs.calendar_paths
      assert "/cal3" in attrs.calendar_paths
    end

    test "parses newline-separated calendar paths" do
      params = %{
        "name" => "Test",
        "provider" => "caldav",
        "url" => "https://example.com",
        "username" => "user",
        "password" => "pass",
        "calendar_paths" => "/cal1\n/cal2\n/cal3"
      }

      assert {:ok, attrs} = Creation.prepare_attrs(params, 1)
      assert length(attrs.calendar_paths) == 3
    end

    test "builds calendar_list from calendar_paths when not provided" do
      params = %{
        "name" => "Test",
        "provider" => "caldav",
        "url" => "https://example.com",
        "username" => "user",
        "password" => "pass",
        "calendar_paths" => "/calendars/user/personal"
      }

      assert {:ok, attrs} = Creation.prepare_attrs(params, 1)
      assert length(attrs.calendar_list) == 1

      calendar = List.first(attrs.calendar_list)
      assert calendar.path == "/calendars/user/personal"
      assert calendar.selected == true
    end

    test "uses provided calendar_list when available" do
      calendar_list = [
        %{id: "cal1", name: "Personal", path: "/cal1", selected: true}
      ]

      params = %{
        "name" => "Test",
        "provider" => "caldav",
        "url" => "https://example.com",
        "username" => "user",
        "password" => "pass",
        "calendar_paths" => "/cal1",
        "calendar_list" => calendar_list
      }

      assert {:ok, attrs} = Creation.prepare_attrs(params, 1)
      assert length(attrs.calendar_list) == 1

      calendar = List.first(attrs.calendar_list)
      assert calendar.id == "cal1"
      assert calendar.name == "Personal"
    end

    test "extracts calendar name from path" do
      params = %{
        "name" => "Test",
        "provider" => "caldav",
        "url" => "https://example.com",
        "username" => "user",
        "password" => "pass",
        "calendar_paths" => "/calendars/user/personal/"
      }

      assert {:ok, attrs} = Creation.prepare_attrs(params, 1)
      calendar = List.first(attrs.calendar_list)

      # Name should be extracted from last path segment
      assert calendar.name == "personal"
    end
  end

  describe "prevalidate_config/1" do
    test "probes a CalDAV config and passes the attrs through when it answers" do
      attrs = %{
        provider: "caldav",
        user_id: 1,
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      # `expect/4` is the assertion that matters here: unlike the OAuth and
      # unknown-provider cases below, a CalDAV config must actually be probed,
      # so exactly one PROPFIND has to be issued. A regression that skipped the
      # probe would still return {:ok, attrs} and leave this expectation
      # unfulfilled, which `verify_on_exit!` reports.
      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: ""}}
      end)

      assert Creation.prevalidate_config(attrs) == {:ok, attrs}
    end

    test "skips validation for OAuth providers" do
      attrs = %{
        provider: "google",
        base_url: "https://www.googleapis.com",
        access_token: "token123",
        refresh_token: "refresh123"
      }

      # OAuth providers skip pre-validation
      assert {:ok, ^attrs} = Creation.prevalidate_config(attrs)
    end

    # A probe failure is never attributable to a single input: the reason comes
    # back as a sanitised sentence, so it is reported against `:discovery`, the
    # form-level key both CalDAV forms already render. It used to be wrapped in
    # a pseudo-changeset whose field was guessed from keywords in that sentence,
    # which prefixed the generic message with "Calendar paths".
    test "reports a failed connection probe form-level rather than against a field" do
      attrs = %{
        provider: "caldav",
        user_id: 1,
        base_url: "https://caldav.example.com",
        username: "invalid",
        password: "wrong"
      }

      assert {:error, %{discovery: message}} = Creation.prevalidate_config(attrs)
      assert byte_size(message) > 0
      refute message =~ "Calendar paths"
    end

    test "handles provider that doesn't exist" do
      attrs = %{
        provider: "unknown_provider",
        base_url: "https://example.com"
      }

      # Should skip validation for unknown provider
      assert {:ok, ^attrs} = Creation.prevalidate_config(attrs)
    end
  end

  describe "ensure_primary_on_first/3" do
    setup do
      user = insert(:user)
      # The primary calendar is recorded on the profile; without one the
      # promotion below is a silent no-op.
      insert(:profile, user: user)

      %{user: user}
    end

    test "sets first integration as primary", %{user: user} do
      integration = insert(:calendar_integration, user: user)

      # Simulate this being the first integration (count_before = 0)
      assert {:ok, primary} = Creation.ensure_primary_on_first(user.id, integration.id, 0)
      assert primary.id == integration.id

      assert {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == integration.id
    end

    test "does not set primary if not first integration", %{user: user} do
      # Create first integration and set as primary
      integration1 = insert(:calendar_integration, user: user)

      CalendarPrimary.set_primary_calendar_integration(
        user.id,
        integration1.id
      )

      # Create second integration
      integration2 = insert(:calendar_integration, user: user)

      # Simulate this being the second integration (count_before = 1)
      assert :ok = Creation.ensure_primary_on_first(user.id, integration2.id, 1)

      # Primary should still be the first integration
      assert {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == integration1.id
    end

    test "returns ok when count is greater than zero" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert :ok = Creation.ensure_primary_on_first(user.id, integration.id, 5)
    end
  end

  describe "create_with_validation/3" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "creates integration and sets as primary if first", %{user: user} do
      # The primary calendar is recorded on the profile; without one the
      # promotion below is a silent no-op.
      insert(:profile, user: user)

      stub(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: ""}}
      end)

      params = %{
        "name" => "Test Calendar",
        "provider" => "caldav",
        "url" => "https://caldav.example.com",
        "username" => "testuser",
        "password" => "testpass",
        "calendar_paths" => ""
      }

      assert {:ok, integration} = Creation.create_with_validation(user.id, params)
      assert integration.name == "Test Calendar"
      assert integration.base_url == "https://caldav.example.com"

      assert [%{id: id}] = CalendarManagement.list_calendar_integrations(user.id)
      assert id == integration.id

      assert {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == integration.id
    end

    test "reports a missing name against the name field", %{user: user} do
      params = %{
        "name" => "",
        "provider" => "invalid"
      }

      # The field the error is keyed under is the whole point: the form renders
      # it next to the offending input, so a bare {:error, _} would not notice
      # the message drifting onto a different field.
      assert Creation.create_with_validation(user.id, params) ==
               {:error, {:form_errors, %{name: "Integration name is required"}}}

      assert CalendarManagement.list_calendar_integrations(user.id) == []
    end

    test "reports a malicious URL against the url field", %{user: user} do
      params = %{
        "name" => "Test",
        "provider" => "caldav",
        "url" => "javascript:alert('xss')",
        "username" => "user",
        "password" => "pass",
        "calendar_paths" => ""
      }

      assert Creation.create_with_validation(user.id, params) ==
               {:error,
                {:form_errors,
                 %{url: "Please enter a valid server URL (e.g., https://cloud.example.com)"}}}

      assert CalendarManagement.list_calendar_integrations(user.id) == []
    end

    test "surfaces a failed connection probe as a form-level error", %{user: user} do
      params = %{
        "name" => "Test Calendar",
        "provider" => "caldav",
        "url" => "https://caldav.example.com",
        "username" => "testuser",
        "password" => "testpass",
        "calendar_paths" => ""
      }

      # `:discovery` is the key both the dashboard and the onboarding CalDAV
      # forms render form-level, so the sanitised reason reaches the user on
      # either surface instead of being logged and replaced with "try again".
      assert {:error, {:form_errors, %{discovery: message}}} =
               Creation.create_with_validation(user.id, params)

      assert byte_size(message) > 0
    end

    test "threads caller metadata through to the security log", %{user: user} do
      # `:metadata` is request provenance for the security log, not a
      # rate-limiting key — the only place it shows up is the entry
      # `SecurityLogger.log_blocked_input/3` writes when a field is sanitised.
      # The username below trips the SQL-injection check, which is what makes
      # that entry appear and the IP observable.
      params = %{
        "name" => "Test",
        "provider" => "caldav",
        "url" => "https://example.com",
        "username" => "admin' OR 1=1 --",
        "password" => "pass",
        "calendar_paths" => ""
      }

      log =
        capture_log([format: "$metadata$message\n", metadata: :all], fn ->
          assert {:error, _reason} =
                   Creation.create_with_validation(user.id, params,
                     metadata: %{ip: "203.0.113.7"}
                   )
        end)

      assert log =~ "Suspicious input sanitised"
      assert log =~ "ip_address=203.0.113.7"
    end
  end
end
