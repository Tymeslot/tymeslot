defmodule Tymeslot.Integrations.Calendar.Ics.ProviderTest do
  @moduledoc """
  Covers the read-only calendar subscription provider: what it refuses to do,
  what its single synthetic calendar looks like, and the fact that its read
  path serves the local event cache rather than the feed.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Ics.Provider
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Security.Encryption

  @feed_url "https://feeds.example.com/secret-address/basic.ics"

  defp subscription_integration(attrs \\ %{}) do
    :calendar_integration
    |> insert(
      Map.merge(
        %{
          provider: "ics_url",
          base_url: "https://feeds.example.com",
          username_encrypted: nil,
          password_encrypted: nil,
          subscription_url_encrypted: Encryption.encrypt(@feed_url)
        },
        attrs
      )
    )
    |> CalendarIntegrationSchema.decrypt_credentials()
  end

  describe "write callbacks" do
    test "creating, updating, and deleting all refuse" do
      client = Provider.new(%{subscription_url: @feed_url})

      assert {:error, :read_only} = Provider.create_event(client, %{summary: "Nope"})
      assert {:error, :read_only} = Provider.update_event(client, "uid", %{summary: "Nope"})
      assert {:error, :read_only} = Provider.delete_event(client, "uid")
    end

    test "no booking client can be built for a subscription" do
      assert Provider.build_booking_client_config(subscription_integration()) == nil
    end
  end

  describe "discover_calendars_for_integration/1" do
    test "returns a single read-only calendar" do
      assert {:ok, [calendar]} =
               Provider.discover_calendars_for_integration(subscription_integration())

      assert calendar.read_only
      assert calendar.selected
      assert calendar.name == "Subscribed calendar"
    end

    test "its calendar is never offered as a booking target" do
      {:ok, calendars} = Provider.discover_calendars_for_integration(subscription_integration())

      assert Selection.selected_calendars(calendars) == calendars
      assert Selection.writable_calendars(calendars) == []
    end
  end

  describe "build_client_configs/1" do
    test "carries the decrypted feed URL and the integration id" do
      integration = subscription_integration()

      assert [client] = Provider.build_client_configs(integration)
      assert client.feed_url == @feed_url
      assert client.calendar_integration_id == integration.id
    end

    test "rewrites a webcal feed URL to https" do
      integration =
        subscription_integration(%{
          subscription_url_encrypted: Encryption.encrypt("webcal://feeds.example.com/basic.ics")
        })

      assert [%{feed_url: "https://feeds.example.com/basic.ics"}] =
               Provider.build_client_configs(integration)
    end
  end

  describe "list_events/2" do
    setup do
      integration = subscription_integration()

      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "ics_url",
        provider_calendar_id: "subscription",
        uid: "timed-event",
        summary: "Sprint planning",
        start_at: ~U[2026-08-10 09:00:00.000000Z],
        end_at: ~U[2026-08-10 10:00:00.000000Z],
        all_day: false
      )

      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "ics_url",
        provider_calendar_id: "subscription",
        uid: "all-day-event",
        summary: "Company offsite",
        start_at: nil,
        end_at: nil,
        start_date: ~D[2026-08-12],
        end_date: ~D[2026-08-13],
        all_day: true
      )

      %{integration: integration, client: hd(Provider.build_client_configs(integration))}
    end

    test "reads the cache rather than the feed", %{client: client} do
      # No HTTP stub is installed: a request would fail the test outright.
      assert {:ok, events} =
               Provider.list_events(client,
                 start_time: ~U[2026-08-01 00:00:00Z],
                 end_time: ~U[2026-08-31 23:59:59Z]
               )

      assert events |> Enum.map(& &1.uid) |> Enum.sort() == ["all-day-event", "timed-event"]
    end

    test "returns all-day events as dates, the shape the conflict checker expects", %{
      client: client
    } do
      {:ok, events} =
        Provider.list_events(client,
          start_time: ~U[2026-08-01 00:00:00Z],
          end_time: ~U[2026-08-31 23:59:59Z]
        )

      all_day = Enum.find(events, &(&1.uid == "all-day-event"))

      assert all_day.start_time == ~D[2026-08-12]
      assert all_day.end_time == ~D[2026-08-13]
    end

    test "excludes events outside the requested range", %{client: client} do
      assert {:ok, []} =
               Provider.list_events(client,
                 start_time: ~U[2026-09-01 00:00:00Z],
                 end_time: ~U[2026-09-30 23:59:59Z]
               )
    end

    test "drops the recurrence rule so cached occurrences are not expanded twice", %{
      client: client
    } do
      {:ok, events} =
        Provider.list_events(client,
          start_time: ~U[2026-08-01 00:00:00Z],
          end_time: ~U[2026-08-31 23:59:59Z]
        )

      assert Enum.all?(events, &is_nil(&1.recurrence_rule))
    end

    test "a client with no integration returns nothing rather than raising" do
      assert {:ok, []} =
               Provider.list_events(%{feed_url: @feed_url},
                 start_time: ~U[2026-08-01 00:00:00Z],
                 end_time: ~U[2026-08-31 23:59:59Z]
               )
    end
  end

  describe "normalise_events/2" do
    test "stamps events with the ics_url provider" do
      raw = [
        %{
          uid: "event-one@example.com",
          summary: "Sprint planning",
          start_time: ~U[2026-08-10 09:00:00Z],
          end_time: ~U[2026-08-10 10:00:00Z]
        }
      ]

      context = %{
        calendar_integration_id: 1,
        provider_calendar_id: "subscription",
        synced_at: DateTime.utc_now()
      }

      assert {:ok, [event]} = Provider.normalise_events(raw, context)
      assert event.provider == :ics_url
      assert event.summary == "Sprint planning"
    end

    test "expands a recurring feed event into occurrences" do
      starts_at = DateTime.add(DateTime.utc_now(), 1, :day)

      raw = [
        %{
          uid: "weekly@example.com",
          summary: "Weekly sync",
          start_time: starts_at,
          end_time: DateTime.add(starts_at, 1, :hour),
          recurrence_rule: "FREQ=WEEKLY;COUNT=3"
        }
      ]

      context = %{
        calendar_integration_id: 1,
        provider_calendar_id: "subscription",
        synced_at: DateTime.utc_now()
      }

      assert {:ok, events} = Provider.normalise_events(raw, context)
      assert length(events) == 3
      assert Enum.all?(events, &(&1.provider == :ics_url))
    end
  end

  describe "validate_config/1" do
    test "accepts an https feed URL" do
      assert :ok = Provider.validate_config(%{subscription_url: @feed_url})
    end

    test "accepts a webcal feed URL" do
      assert :ok =
               Provider.validate_config(%{subscription_url: "webcal://feeds.example.com/a.ics"})
    end

    test "rejects a missing URL" do
      assert {:error, message} = Provider.validate_config(%{})
      assert message =~ "subscription_url"
    end

    test "rejects a URL that is not http(s)" do
      assert {:error, _message} =
               Provider.validate_config(%{subscription_url: "file:///etc/passwd"})
    end
  end
end
