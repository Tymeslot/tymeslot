defmodule Tymeslot.Integrations.Calendar.OwnerActionsTest do
  @moduledoc """
  An organiser's changes to their own calendars are scoped and metered in the
  context itself: another user's integration id is not found, and every
  change draws on the owner's budget whoever calls it.
  """
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncIcsCalendarWorker

  defp insert_subscription(user, attrs \\ []) do
    insert(
      :calendar_integration,
      Keyword.merge(
        [
          user: user,
          provider: "ics_url",
          base_url: "https://feeds.example.com",
          username_encrypted: nil,
          password_encrypted: nil,
          subscription_url_encrypted: Encryption.encrypt("https://feeds.example.com/feed.ics")
        ],
        attrs
      )
    )
  end

  defp exhaust_write_budget(user_id) do
    fn -> RateLimiter.check(:integration_write, user_id) end
    |> Stream.repeatedly()
    |> Enum.find(&match?({:error, :rate_limited, _message}, &1))
  end

  describe "another user's integration" do
    setup do
      owner = insert(:user)
      intruder = insert(:user)

      integration =
        insert(:calendar_integration,
          user: owner,
          provider: "caldav",
          name: "Owner's",
          colour: nil,
          calendar_list: [%{"id" => "/cal/a/", "path" => "/cal/a/", "selected" => true}]
        )

      %{intruder: intruder, integration: integration}
    end

    test "cannot be switched off", %{intruder: intruder, integration: integration} do
      assert {:error, :not_found} = Calendar.toggle_integration(intruder.id, integration.id)
      assert Repo.reload!(integration).is_active
    end

    test "cannot be renamed", %{intruder: intruder, integration: integration} do
      assert {:error, :not_found} =
               Calendar.rename_integration(intruder.id, integration.id, "Mine now", %{})

      assert Repo.reload!(integration).name == "Owner's"
    end

    test "cannot be recoloured", %{intruder: intruder, integration: integration} do
      assert {:error, :not_found} =
               Calendar.set_integration_colour(intruder.id, integration.id, "grape")

      assert Repo.reload!(integration).colour == nil
    end

    test "cannot have its calendars unticked", %{intruder: intruder, integration: integration} do
      assert {:error, :not_found} =
               Calendar.set_calendar_state(intruder.id, integration.id, "/cal/a/", :off)

      assert [%{selected: true}] = Repo.reload!(integration).calendar_list
    end

    test "cannot be deleted", %{intruder: intruder, integration: integration} do
      assert {:error, :not_found} =
               Calendar.delete_with_primary_reassignment_and_invalidate(
                 intruder.id,
                 integration.id
               )

      assert Repo.get(CalendarIntegrationSchema, integration.id)
    end
  end

  describe "the owner's write budget" do
    test "is charged by a change made through the context" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          calendar_list: [%{"id" => "/cal/a/", "path" => "/cal/a/", "selected" => true}]
        )

      assert {:error, :rate_limited, _message} = exhaust_write_budget(user.id)

      assert {:error, {:rate_limited, message}} =
               Calendar.set_calendar_state(user.id, integration.id, "/cal/a/", :off)

      assert byte_size(message) > 0
      assert [%{selected: true}] = Repo.reload!(integration).calendar_list

      assert {:error, {:rate_limited, _message}} =
               Calendar.toggle_integration(user.id, integration.id)

      assert Repo.reload!(integration).is_active
    end

    test "draws one write for each change" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "caldav")

      {:ok, _toggled} = Calendar.toggle_integration(user.id, integration.id)

      writes_left =
        fn -> RateLimiter.check(:integration_write, user.id) end
        |> Stream.repeatedly()
        |> Enum.take_while(&(&1 == :ok))
        |> length()

      assert writes_left == 29
    end
  end

  describe "refresh_all_integrations/1" do
    test "refreshes each active integration of the user once, by name" do
      user = insert(:user)
      active = insert_subscription(user, name: "Team feed")
      _paused = insert_subscription(user, name: "Paused feed", is_active: false)
      _foreign = insert_subscription(insert(:user), name: "Someone else's feed")

      assert {:ok, [{"Team feed", :ok}]} = Calendar.refresh_all_integrations(user.id)

      assert [job] = all_enqueued(worker: SyncIcsCalendarWorker)
      assert job.args["calendar_integration_id"] == active.id
    end

    test "is refused once the refresh budget is spent" do
      user = insert(:user)
      insert_subscription(user)

      fn -> RateLimiter.check(:calendar_refresh, user.id) end
      |> Stream.repeatedly()
      |> Enum.find(&match?({:error, :rate_limited, _message}, &1))

      assert {:error, {:rate_limited, _message}} = Calendar.refresh_all_integrations(user.id)
      assert all_enqueued(worker: SyncIcsCalendarWorker) == []
    end
  end
end
