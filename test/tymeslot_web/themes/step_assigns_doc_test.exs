defmodule TymeslotWeb.Themes.StepAssignsDocTest do
  @moduledoc """
  The guide's table of the assigns a booking step may read
  (`docs/THEME_DEVELOPMENT_GUIDE.md`, §"Step Components") is what a new
  theme's steps are written against. Every assign it lists as present from
  mount must be on every registered theme's booking page as soon as it has
  mounted, so the table cannot promise one the page does not hold.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :docs
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.TestMocks
  alias TymeslotWeb.ThemeTestMatrix

  @guide "docs/THEME_DEVELOPMENT_GUIDE.md"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  @row ~r/^\| `([a-z_]+)` \| [^|]+ \| (mount|optional) \|/

  defp table_rows do
    [_before, rest] = @guide |> File.read!() |> String.split("<!-- step-assigns:start -->")
    [table, _after] = String.split(rest, "<!-- step-assigns:end -->")

    table
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "| `"))
  end

  defp declared do
    for line <- table_rows(),
        [_row, name, presence] <- [Regex.run(@row, line)],
        do: {name, presence}
  end

  test "the table lists assigns, most of them present from mount" do
    rows = declared()

    assert Enum.count(rows, &match?({_name, "mount"}, &1)) > 40
    assert Enum.any?(rows, &match?({_name, "optional"}, &1))
  end

  # A row the pattern does not read would be skipped by every check below,
  # so a typo in its name or its "Present" column must fail here instead.
  test "every row of the table names one assign and says mount or optional" do
    assert Enum.reject(table_rows(), &Regex.match?(@row, &1)) == []
  end

  for theme <- ThemeTestMatrix.registered() do
    test "#{theme.name}: the page holds every assign the table lists from mount", %{conn: conn} do
      %{profile: profile} =
        seed_booking_account(unquote(theme.id), "assigns-#{unquote(theme.slug)}", "Etc/UTC")

      {:ok, view, _html} = live(conn, "/#{profile.username}")

      held =
        view.pid |> :sys.get_state() |> Map.fetch!(:socket) |> Map.fetch!(:assigns) |> Map.keys()

      held = MapSet.new(held, &Atom.to_string/1)

      missing = for {name, "mount"} <- declared(), name not in held, do: name
      assert missing == [], "listed as present from mount but absent: #{inspect(missing)}"
    end
  end
end
