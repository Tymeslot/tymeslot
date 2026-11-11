defmodule TymeslotWeb.Live.Scheduling.EmbeddedRefusalRedirectTest do
  @moduledoc """
  A guest refused inside an embedded booking page (an unknown slug, a type
  with no times open, an invitation-only type without a valid link) is sent to
  the organiser's profile page. That redirect has to stay an embed, in the
  embed's theme, layout and colour, or the guest lands on the full profile
  page inside the host's iframe. Only values the page verified are carried:
  a crafted `?embed=1&parent-origin=` on a page that is not embedded mints
  nothing.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :embed
  @moduletag :live

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.BookingTestHelpers
  alias Tymeslot.Invitations
  alias Tymeslot.Repo

  @username "refusedembedhost"
  @timezone "Etc/UTC"
  @embed_query "embed=1&theme=2&layout=column&primary-color=%23ff0000&timezone=#{@timezone}"

  setup do
    %{user: user, profile: profile} =
      BookingTestHelpers.seed_booking_account("1", @username, @timezone)

    profile =
      profile
      |> Changeset.change(allowed_embed_domains: ["embedder.test"])
      |> Repo.update!()

    %{user: user, profile: profile}
  end

  defp embedded(conn), do: put_req_header(conn, "referer", "https://embedder.test/page")

  defp assert_stays_embedded(to) do
    assert %URI{path: "/" <> @username} = URI.parse(to)
    assert_carries_embed(to)
  end

  defp assert_carries_embed(to) do
    params = to |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert params["embed"] == "1"
    assert params["parent-origin"] == "https://embedder.test"
    assert params["theme"] == "2"
    assert params["layout"] == "column"
    assert params["primary-color"] == "#ff0000"
  end

  @tag :capture_log
  test "an unknown slug keeps the embed", %{conn: conn} do
    assert {:error, {:redirect, %{to: to, flash: flash}}} =
             conn |> embedded() |> live("/#{@username}/no-such-type?#{@embed_query}")

    assert flash["error"] =~ "Invalid meeting type"
    assert_stays_embedded(to)
  end

  @tag :capture_log
  test "a type with no times open keeps the embed", %{conn: conn, user: user} do
    insert(:meeting_type,
      user: user,
      name: "Fixed",
      slug: "fixed",
      duration_minutes: 30,
      is_active: true,
      fixed_dates: true,
      max_participants: 1
    )

    assert {:error, {:redirect, %{to: to, flash: flash}}} =
             conn |> embedded() |> live("/#{@username}/fixed?#{@embed_query}")

    assert flash["info"] == "This meeting type has no times open for booking right now."
    assert_stays_embedded(to)
  end

  @tag :capture_log
  test "an invitation-only type without a link keeps the embed", %{conn: conn, user: user} do
    insert(:meeting_type,
      user: user,
      name: "Coaching",
      slug: "coaching",
      duration_minutes: 30,
      is_active: true,
      invitation_only: true
    )

    assert {:error, {:redirect, %{to: to}}} =
             conn |> embedded() |> live("/#{@username}/coaching?#{@embed_query}")

    assert_stays_embedded(to)
  end

  @tag :capture_log
  test "a wrong invitation link keeps the embed too", %{conn: conn, user: user} do
    type =
      insert(:meeting_type,
        user: user,
        name: "Coaching",
        slug: "coaching",
        duration_minutes: 30,
        is_active: true,
        invitation_only: true
      )

    {:ok, _invitation} = Invitations.create(user.id, type, %{name: "Ada", email: "a@example.com"})

    assert {:error, {:redirect, %{to: to}}} =
             conn |> embedded() |> live("/#{@username}/coaching?invite=wrong&#{@embed_query}")

    assert_stays_embedded(to)
  end

  @tag :capture_log
  test "embed parameters on a page that is not embedded are not carried", %{conn: conn} do
    # Without `embed=1` the embed token plug signs nothing, so the page is not
    # embedded and none of the raw params may reach the redirect.
    assert {:error, {:redirect, %{to: to}}} =
             live(
               conn,
               "/#{@username}/no-such-type?parent-origin=https%3A%2F%2Fevil.test&theme=2&layout=column&primary-color=%23ff0000&timezone=#{@timezone}"
             )

    assert to == "/" <> @username
  end

  @tag :capture_log
  test "a booking step entered without a chosen time sends the guest back to the schedule inside the embed",
       %{conn: conn, user: user} do
    insert(:meeting_type,
      user: user,
      name: "Quick chat",
      slug: "quick-chat",
      duration_minutes: 30,
      is_active: true
    )

    assert {:error, {:redirect, %{to: to}}} =
             conn |> embedded() |> live("/#{@username}/quick-chat/book?#{@embed_query}")

    assert %URI{path: path} = URI.parse(to)
    assert path == "/#{@username}/quick-chat"
    assert_carries_embed(to)
  end

  @tag :capture_log
  test "the same step, not embedded, carries no embed parameters", %{conn: conn, user: user} do
    insert(:meeting_type,
      user: user,
      name: "Quick chat",
      slug: "quick-chat",
      duration_minutes: 30,
      is_active: true
    )

    assert {:error, {:redirect, %{to: to}}} =
             live(
               conn,
               "/#{@username}/quick-chat/book?parent-origin=https%3A%2F%2Fevil.test&layout=column&timezone=#{@timezone}"
             )

    assert to == "/#{@username}/quick-chat"
  end
end
