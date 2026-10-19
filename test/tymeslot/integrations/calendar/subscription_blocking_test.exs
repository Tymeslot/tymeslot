defmodule Tymeslot.Integrations.Calendar.SubscriptionBlockingTest do
  @moduledoc """
  A subscribed feed blocks availability, as it always has, unless the form it
  was added from asked for it to be shown only.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.Calendar.Creation

  setup :verify_on_exit!

  setup do
    stub(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
      {:ok,
       %Req.Response{
         status: 200,
         body: "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//Test//EN\nEND:VCALENDAR\n",
         headers: %{}
       }}
    end)

    %{user: insert(:user)}
  end

  defp subscribe(user, extra) do
    params =
      Map.merge(
        %{"name" => "Team feed", "url" => "https://feeds.example.com/team-#{user.id}.ics"},
        extra
      )

    {:ok, integration} = Creation.create_subscription_with_validation(user.id, params, [])
    [entry] = integration.calendar_list
    entry
  end

  test "blocks when the form says nothing", %{user: user} do
    assert %{blocks_availability: true} = subscribe(user, %{})
  end

  test "blocks when the form asks it to", %{user: user} do
    assert %{blocks_availability: true} = subscribe(user, %{"blocks_availability" => "true"})
  end

  test "is shown only when the form asks for that", %{user: user} do
    assert %{blocks_availability: false} = subscribe(user, %{"blocks_availability" => "false"})
  end
end
