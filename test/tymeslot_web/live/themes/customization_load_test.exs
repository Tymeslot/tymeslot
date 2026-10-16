defmodule TymeslotWeb.Live.Themes.CustomizationLoadTest do
  @moduledoc """
  A booking page reads the organiser's theme customisation once per mount:
  once on the static render and once on the connected mount, never again from
  the theme's own mount or `handle_params`.
  """
  # The query handler is global, so a concurrent test would add its own reads.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :themes
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.TestMocks
  alias TymeslotWeb.ThemeTestMatrix

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_calendar_mocks()

    user = insert(:user)
    profile = insert(:profile, user: user, username: "load-once")
    insert(:calendar_integration, user: user, is_active: true)
    insert(:meeting_type, user: user, name: "Quick Chat", duration_minutes: 30)

    parent = self()
    ref = make_ref()
    handler_id = "customization-load-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, %{source: source}, _config ->
        if source == "theme_customizations", do: send(parent, {:customization_read, ref})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{profile: profile, ref: ref}
  end

  for theme_id <- ThemeTestMatrix.ids() do
    test "theme #{theme_id}: the booking page reads the customisation once per mount",
         %{conn: conn, profile: profile, ref: ref} do
      {:ok, _view, _html} = live(conn, "/#{profile.username}?theme=#{unquote(theme_id)}")

      assert reads(ref) == 2
    end
  end

  defp reads(ref, count \\ 0) do
    receive do
      {:customization_read, ^ref} -> reads(ref, count + 1)
    after
      0 -> count
    end
  end
end
