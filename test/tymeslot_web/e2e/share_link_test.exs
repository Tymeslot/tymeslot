defmodule TymeslotWeb.E2E.ShareLinkTest do
  @moduledoc """
  "Send them your link" on the onboarding live step (`ShareLink`, in
  `assets/js/hooks/share_link.js`) hands the server-built message to the
  device: to the share sheet where there is one and no recipient was typed,
  and as a mail draft addressed to the first person once their address is.
  Either way the server is told, the card confirms how, and Go to dashboard
  unlocks.

  Neither the share sheet nor a mail client exists in a driven Chrome, so
  `navigator.share` and the anchor click that opens a `mailto:` are replaced
  on the page with recorders (`record_sharing/1`).
  """

  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :onboarding

  import TymeslotWeb.OnboardingTestHelpers, only: [stub_free_calendar: 0]

  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias TymeslotWeb.Endpoint

  @send "#onboarding-send-link"
  @kept "#onboarding-kept"

  setup do
    stub_free_calendar()
    :ok
  end

  feature "the message goes to the share sheet, then to a draft addressed to the first person",
          %{session: session} do
    user = host_on_the_live_step()
    url = "#{Endpoint.url()}/#{Profiles.get_profile(user.id).username}"
    message = "Hi Ada, you can pick a time with me here: #{url}"

    session =
      session
      |> log_in(user)
      |> visit("/onboarding/ready")
      |> wait_for_live()
      |> assert_has(css(~s(#onboarding-finish[aria-disabled="true"])))
      |> record_sharing()
      |> fill_in(css("#onboarding-first-person-name"), with: "Ada")
      |> assert_has(css("#{@send}[data-share-text='#{message}']"))
      |> click(css(@send))
      |> assert_has(css(@kept, text: "Sent"))
      |> assert_has(css("#onboarding-finish:not([aria-disabled])"))

    assert recorded(session) == %{"shared" => [%{"text" => message}], "opened" => []}

    # With an address typed, the draft goes to it even where a sheet exists.
    session
    |> fill_in(css("#onboarding-first-person-email"), with: "ada@example.com")
    |> assert_has(css("#{@send}[data-share-to='ada@example.com']"))
    |> click(css(@send))
    |> assert_has(css(@kept, text: "Opened in your email app"))

    assert %{"opened" => [draft]} = recorded(session)

    assert draft ==
             "mailto:ada@example.com?subject=Book%20a%20time%20with%20me&body=" <>
               URI.encode(message, &URI.char_unreserved?/1)

    assert %DateTime{} = Profiles.get_profile(user.id).booking_link_first_shared_at
  end

  # As the wizard leaves a host who has chosen a link, connected a calendar
  # and confirmed a meeting type: the live step is the next one.
  defp host_on_the_live_step do
    user = insert(:user, onboarding_completed_at: nil)
    insert(:profile, user: user, username: "sharehost#{System.unique_integer([:positive])}")
    insert(:calendar_integration, user: user)
    {:ok, _confirmed} = Onboarding.confirm_meeting_step(user)
    user
  end

  defp log_in(session, user) do
    session
    |> visit("/auth/login")
    |> wait_for_live()
    |> fill_in(text_field("email"), with: user.email)
    |> fill_in(css("#password-input"), with: default_password())
    |> click(css("button[type='submit']"))
    |> assert_has(css("#onboarding-stage"))
  end

  # A share sheet that takes what it is given, and a mail client that
  # notes the draft it would open instead of leaving the page.
  defp record_sharing(session) do
    execute_script(session, """
    window.__sharing = {shared: [], opened: []};
    navigator.share = (data) => { window.__sharing.shared.push(data); return Promise.resolve(); };
    navigator.canShare = () => true;
    HTMLAnchorElement.prototype.click = function () { window.__sharing.opened.push(this.href); };
    """)
  end

  defp recorded(session), do: evaluate_script(session, "return window.__sharing")
end
