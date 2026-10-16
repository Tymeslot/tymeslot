defmodule TymeslotWeb.E2E.EmbedPrimaryColourTest do
  @moduledoc """
  An embed's `data-primary-color` must repaint the booking page it frames.

  `embed.js` turns the attribute into `?primary-color=` on the iframe URL
  (pinned in `assets/js/__tests__/embed.test.js`). This frames that URL in a
  real browser, through the embed token, the cookie-free embed socket and the
  embed auth hook, and reads the colours the page actually resolved, in every
  theme.

  The URL is framed rather than visited: only a framed page connects over
  `/embed-live` and goes through the embed token; a top-level visit is served
  as an ordinary page (`EmbedTokenPlug`, `Sec-Fetch-Dest: document`).
  The host page is same-origin (`frame-ancestors` allows `'self'` whenever
  the profile has an allowlist) and frames with `referrerpolicy="no-referrer"`,
  so the embed token takes its parent origin from `?parent-origin=`, as it
  does for an embedder that strips the Referer.
  """
  use TymeslotWeb.BrowserCase, async: false

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias TymeslotWeb.ThemeTestMatrix

  @moduletag :e2e
  @moduletag :themes

  @override "#e11d48"
  @parent_origin "http://embedder.test"

  feature "the embed's primary colour reaches the rendered page in every theme",
          %{session: session} do
    profile = create_embeddable_profile()
    session = visit(session, "/#{profile.username}")

    for theme_id <- ThemeTestMatrix.ids(), reduce: session do
      acc ->
        {acc, default_primary, default_solid} =
          framed_colours(acc, embed_path(profile.username, theme_id, nil))

        {acc, primary, solid} =
          framed_colours(acc, embed_path(profile.username, theme_id, @override))

        refute default_primary == @override
        assert primary == @override, "theme #{theme_id}: page resolved #{primary}"

        refute solid == default_solid,
               "theme #{theme_id}: the filled-control surface did not follow the override"

        acc
    end
  end

  feature "a language switch inside the frame keeps the page embedded and its colour",
          %{session: session} do
    # The switcher issues a full redirect inside the iframe. It used to rebuild
    # the URL without the embed parameters, so the page came back without its
    # embed token and fell back to the organiser's theme, layout and colour.
    profile = create_embeddable_profile()
    theme_id = List.last(ThemeTestMatrix.ids())

    path =
      embed_path(profile.username, theme_id, @override) <>
        "&" <> URI.encode_query(%{"layout" => "column"})

    session =
      session
      |> visit("/#{profile.username}")
      |> frame(path)
      |> click(css(".lang-switcher button[phx-click='toggle_language_dropdown']"))
      |> click(css("button[phx-click='change_locale'][phx-value-locale='de']"))
      |> assert_has(css("html[lang='de'][data-embedded][data-embed-layout='column']"))
      |> assert_has(css("[data-phx-main].phx-connected"))

    {session, primary} = root_property(session, "--theme-primary")
    assert primary == @override, "after the switch the page resolved #{primary}"

    {session, html_class} = root_attribute(session, "class")
    assert html_class =~ "theme-#{theme_id} "

    focus_default_frame(session)
  end

  # Frames `path` in a fresh iframe on the host page, waits for its LiveView to
  # connect (a rejected embed redirects to `/embed-unavailable`, which has no
  # LiveView, so this fails loudly rather than reading the wrong page), and
  # reads the resolved primary and filled-control colours inside it.
  defp framed_colours(session, path) do
    session = frame(session, path)

    {session, primary} = root_property(session, "--theme-primary")
    {session, solid} = root_property(session, "--theme-primary-solid")

    {focus_default_frame(session), primary, solid}
  end

  defp frame(session, path) do
    session
    |> execute_script(
      """
      document.getElementById("embed-frame")?.remove();
      const frame = document.createElement("iframe");
      frame.id = "embed-frame";
      frame.referrerPolicy = "no-referrer";
      frame.style.width = "1000px";
      frame.style.height = "800px";
      frame.src = arguments[0];
      document.body.appendChild(frame);
      """,
      [path]
    )
    |> focus_frame(css("#embed-frame"))
    |> assert_has(css("[data-phx-main].phx-connected"))
  end

  defp root_attribute(session, name) do
    me = self()
    ref = make_ref()

    session =
      execute_script(
        session,
        "return document.documentElement.getAttribute(arguments[0]);",
        [name],
        fn value -> send(me, {:attribute, ref, value}) end
      )

    assert_receive {:attribute, ^ref, value}, 5_000
    {session, value}
  end

  defp root_property(session, name) do
    me = self()
    ref = make_ref()

    session =
      execute_script(
        session,
        "return getComputedStyle(document.documentElement).getPropertyValue(arguments[0]).trim();",
        [name],
        fn value -> send(me, {:property, ref, value}) end
      )

    assert_receive {:property, ^ref, value}, 5_000
    {session, value}
  end

  defp embed_path(username, theme_id, colour) do
    query =
      [{"embed", "1"}, {"parent-origin", @parent_origin}, {"theme", theme_id}] ++
        if(colour, do: [{"primary-color", colour}], else: [])

    "/#{username}?" <> URI.encode_query(query)
  end

  defp create_embeddable_profile do
    user = create_onboarded_user()
    insert(:calendar_integration, user_id: user.id, user: user)

    {:ok, _meeting_type} =
      MeetingTypes.create_meeting_type(%{
        user_id: user.id,
        name: "Embed Colour Check",
        duration_minutes: 30,
        is_active: true
      })

    user.id
    |> Profiles.get_profile()
    |> Changeset.change(allowed_embed_domains: ["embedder.test"])
    |> Repo.update!()
  end
end
