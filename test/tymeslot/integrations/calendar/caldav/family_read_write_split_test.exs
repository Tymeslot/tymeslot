defmodule Tymeslot.Integrations.Calendar.CalDAV.FamilyReadWriteSplitTest do
  # Every CalDAV-family member reads from each calendar the organiser
  # selected and writes only to the writable ones. The split is made once, in
  # `ProviderCommon.caldav_build_client_configs/1`, and each member's `new/1`
  # must carry it through to the client it builds.
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalDAV.Family
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.Runtime.ClientManager

  setup do
    %{user: insert(:user)}
  end

  # A calendar shared read-only (a team rota, a subscribed calendar) cannot
  # take a booking, but the organiser selected it so that its events block
  # time, as Google's read-only calendars and a subscribed feed's do.
  describe "a read-only calendar selected on a CalDAV-family integration" do
    for provider <- Enum.map(Family.members(), &Atom.to_string/1) do
      test "gets a #{provider} read client, but is never a write target", %{user: user} do
        inserted =
          insert(:calendar_integration,
            user: user,
            provider: unquote(provider),
            base_url: "https://cal.example.com",
            calendar_paths: ["/cal/bookings/", "/cal/rota/"],
            default_booking_calendar_id: "/cal/bookings/",
            calendar_list: [
              %{id: "/cal/bookings/", path: "/cal/bookings/", name: "Bookings", selected: true},
              %{
                id: "/cal/rota/",
                path: "/cal/rota/",
                name: "Team rota",
                selected: true,
                read_only: true
              }
            ]
          )

        {:ok, integration} = Management.fetch_integration_for_user(inserted.id, user.id)

        reads = ClientManager.clients_for_integration(integration)

        assert reads |> Enum.map(& &1.client.calendar_paths) |> Enum.sort() ==
                 [["/cal/bookings/"], ["/cal/rota/"]]

        assert Enum.all?(reads, &(&1.client.writable_calendar_paths == ["/cal/bookings/"]))

        assert [write_client] = ClientManager.writable_clients_for_integration(integration)
        assert write_client == ClientManager.booking_client({integration.id, user.id})
        assert write_client in reads
        refute Enum.any?(write_client.client.calendar_paths, &(&1 =~ "/cal/rota"))
      end
    end

    test "counts towards availability", %{user: user} do
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        base_url: "https://cal.example.com",
        calendar_paths: ["/cal/bookings/", "/cal/rota/"],
        calendar_list: [
          %{id: "/cal/bookings/", path: "/cal/bookings/", name: "Bookings", selected: true},
          %{id: "/cal/rota/", path: "/cal/rota/", name: "Rota", selected: true, read_only: true},
          %{id: "/cal/old/", path: "/cal/old/", name: "Old", selected: false, read_only: true}
        ]
      )

      {clients, []} = ClientManager.availability_sources(user.id)

      assert clients |> Enum.flat_map(& &1.client.calendar_paths) |> Enum.sort() ==
               ["/cal/bookings/", "/cal/rota/"]
    end

    test "stops counting towards availability once set to show only, but stays readable", %{
      user: user
    } do
      inserted =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          base_url: "https://cal.example.com",
          calendar_paths: ["/cal/bookings/", "/cal/rota/"],
          calendar_list: [
            %{id: "/cal/bookings/", path: "/cal/bookings/", name: "Bookings", selected: true},
            %{
              id: "/cal/rota/",
              path: "/cal/rota/",
              name: "Rota",
              selected: true,
              read_only: true,
              blocks_availability: false
            }
          ]
        )

      {clients, []} = ClientManager.availability_sources(user.id)

      assert Enum.flat_map(clients, & &1.client.calendar_paths) == ["/cal/bookings/"]

      {:ok, integration} = Management.fetch_integration_for_user(inserted.id, user.id)

      assert integration
             |> ClientManager.clients_for_integration()
             |> Enum.flat_map(& &1.client.calendar_paths)
             |> Enum.sort() == ["/cal/bookings/", "/cal/rota/"]
    end
  end
end
