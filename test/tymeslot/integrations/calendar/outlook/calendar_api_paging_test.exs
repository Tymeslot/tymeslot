defmodule Tymeslot.Integrations.Calendar.Outlook.CalendarAPIPagingTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations
  @moduletag :calendar

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  # A busy calendar's window runs past one page of 1,000 occurrences; every
  # busy slot after the first page must still reach availability.
  describe "list reads follow every page" do
    setup do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      %{integration: integration}
    end

    defp page(values, next \\ nil) do
      body =
        if next, do: %{"value" => values, "@odata.nextLink" => next}, else: %{"value" => values}

      {:ok, %Req.Response{status: 200, body: Jason.encode!(body)}}
    end

    defp expect_two_pages(first_path, first_values, second_values) do
      next = "https://graph.microsoft.com/v1.0#{first_path}?$skiptoken=page2"

      expect(Tymeslot.HTTPClientMock, :request, 2, fn :get, url, _body, headers, _opts ->
        if String.contains?(url, "skiptoken=page2") do
          # The second page is read in UTC, like the first.
          assert Enum.any?(headers, fn {k, v} ->
                   String.downcase(k) == "prefer" and v =~ ~s(outlook.timezone="UTC")
                 end)

          page(second_values)
        else
          assert String.contains?(url, first_path)
          page(first_values, next)
        end
      end)
    end

    test "list_events/4 returns the events of every page", %{integration: integration} do
      expect_two_pages("/me/calendars/cal1/calendarView", [%{"id" => "e1"}], [%{"id" => "e2"}])
      now = DateTime.utc_now()

      assert {:ok, events} = CalendarAPI.list_events(integration, "cal1", now, now)
      assert Enum.map(events, & &1["id"]) == ["e1", "e2"]
    end

    test "list_instances/4 returns the occurrences of every page", %{integration: integration} do
      expect_two_pages("/me/events/master/instances", [%{"id" => "o1"}], [%{"id" => "o2"}])
      now = DateTime.utc_now()

      assert {:ok, events} = CalendarAPI.list_instances(integration, "master", now, now)
      assert Enum.map(events, & &1["id"]) == ["o1", "o2"]
    end

    test "list_calendars/1 returns the calendars of every page", %{integration: integration} do
      expect_two_pages("/me/calendars", [%{"id" => "cal1"}], [%{"id" => "cal2"}])

      assert {:ok, calendars} = CalendarAPI.list_calendars(integration)
      assert Enum.map(calendars, & &1["id"]) == ["cal1", "cal2"]
    end

    test "a later page that fails fails the read, rather than returning part of it", %{
      integration: integration
    } do
      expect(Tymeslot.HTTPClientMock, :request, 2, fn :get, url, _body, _headers, _opts ->
        if String.contains?(url, "skiptoken"),
          do: {:ok, %Req.Response{status: 500, body: ""}},
          else:
            page(
              [%{"id" => "e1"}],
              "https://graph.microsoft.com/v1.0/me/calendarView?$skiptoken=x"
            )
      end)

      now = DateTime.utc_now()

      assert {:error, :server_error, _message} =
               CalendarAPI.list_primary_events(integration, now, now)
    end

    test "a next link that never ends is refused at the page cap", %{integration: integration} do
      stub(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        page(
          [%{"id" => "e"}],
          "https://graph.microsoft.com/v1.0/me/calendarView?$skiptoken=again"
        )
      end)

      now = DateTime.utc_now()

      assert {:error, :too_many_pages, _message} =
               CalendarAPI.list_primary_events(integration, now, now)
    end
  end
end
