defmodule TymeslotWeb.Themes.Shared.DefaultPages do
  @moduledoc """
  The meeting, poll and payment pages of a theme that declares
  `use TymeslotWeb.Themes.Core.Theme, page_shell: &MyShell.page_shell/1`:
  each page's shared body (`MeetingPageBodies`, `PollVotingComponents`,
  `PaymentReturnComponents`) inside the theme's shell.

  The shell is a function component. It receives `page` (`:reschedule`,
  `:cancel`, `:cancel_confirmed`, `:poll`, `:payment_processing`,
  `:payment_cancelled`), the page's `theme_tokens` (`nil` on a payment
  page's dead render, which reads no data), `locale` and
  `language_dropdown_open`, and the body as its inner block; it draws the theme's wrapper and card (with the
  `booker-card` hook class) around it.

  Every body sits in `<div class="manage-page manage-page--<page>"
  data-testid="<theme key>-<page>">`, so the payment pages carry the
  `<key>-payment-processing` and `<key>-payment-cancelled` ids the payment
  return suite tells themes apart by. Like the meeting pages, the payment
  pages open with a status icon (`MeetingPageBodies.status_icon/1`), and
  `manage-pages.css` gives their heading the meeting pages' centred title.
  """

  use Phoenix.Component

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.Components.MeetingPageBodies
  alias TymeslotWeb.Themes.Shared.{PaymentReturn, PaymentReturnComponents, PollVotingComponents}

  @type shell :: (map() -> Phoenix.LiveView.Rendered.t())

  @meeting_actions [:reschedule, :cancel, :cancel_confirmed]

  @doc "A meeting page (`render_meeting_action/2`); any other action raises."
  @spec meeting_action(map(), atom(), shell()) :: Phoenix.LiveView.Rendered.t()
  def meeting_action(assigns, action, shell) when action in @meeting_actions,
    do: page(assigns, action, shell)

  def meeting_action(_assigns, action, _shell), do: raise("Unsupported meeting action: #{action}")

  @doc "The poll voting page (`render_poll_action/1`)."
  @spec poll(map(), shell()) :: Phoenix.LiveView.Rendered.t()
  def poll(assigns, shell), do: page(assigns, :poll, shell)

  @doc "A payment return page (`render_payment_page/2`)."
  @spec payment(map(), :processing | :cancelled, shell()) :: Phoenix.LiveView.Rendered.t()
  def payment(assigns, :processing, shell), do: page(assigns, :payment_processing, shell)
  def payment(assigns, :cancelled, shell), do: page(assigns, :payment_cancelled, shell)

  # The bodies are called as functions, not as `<.component>`, so their attr
  # defaults do not apply: the optional keys any body reads are set here.
  defp page(assigns, page, shell) do
    slug = page |> Atom.to_string() |> String.replace("_", "-")

    assigns =
      assign(assigns,
        page: page,
        page_shell: shell,
        page_testid: testid(assigns[:theme_id], slug),
        page_class: "manage-page--" <> slug,
        loading: assigns[:loading] || false,
        meeting_kept: assigns[:meeting_kept] || false,
        meeting_uid: assigns[:meeting_uid],
        organizer_profile: assigns[:organizer_profile],
        participant: assigns[:participant]
      )

    ~H"""
    <.shell
      page_shell={@page_shell}
      page={@page}
      theme_tokens={assigns[:theme_tokens]}
      locale={assigns[:locale]}
      language_dropdown_open={assigns[:language_dropdown_open]}
    >
      <div class={["manage-page", @page_class]} data-testid={@page_testid}>
        {body(assigns)}
      </div>
    </.shell>
    """
  end

  # The shell is chosen at runtime (as `SchedulingPage` applies a theme's
  # wrapper), so it is called directly with the assigns it documents.
  defp shell(assigns) do
    {shell, assigns} = Map.pop(assigns, :page_shell)
    shell.(assigns)
  end

  defp body(%{page: :reschedule} = assigns), do: MeetingPageBodies.reschedule(assigns)
  defp body(%{page: :cancel} = assigns), do: MeetingPageBodies.cancel(assigns)
  defp body(%{page: :cancel_confirmed} = assigns), do: MeetingPageBodies.cancel_confirmed(assigns)

  defp body(%{page: :poll} = assigns) do
    ~H"""
    <PollVotingComponents.poll_content
      poll={@poll}
      tallies={@tallies}
      voting_open={@voting_open}
      participant={@participant}
    />
    """
  end

  defp body(%{page: :payment_processing} = assigns) do
    outcome = PaymentReturn.outcome(assigns.loading, assigns.payment, assigns.meeting)
    assigns = assign(assigns, :status, payment_status(outcome))

    ~H"""
    <MeetingPageBodies.status_icon icon={elem(@status, 0)} tone={elem(@status, 1)} />
    <PaymentReturnComponents.processing_body
      loading={@loading}
      payment={@payment}
      meeting={@meeting}
      rebook_path={@rebook_path}
    />
    """
  end

  defp body(%{page: :payment_cancelled} = assigns) do
    ~H"""
    <MeetingPageBodies.status_icon icon="hero-x-circle" tone="danger" />
    <PaymentReturnComponents.cancelled_body rebook_path={@rebook_path} />
    """
  end

  # The processing page's icon follows its outcome: a clock while the
  # booking waits (on the payment, or on the organiser's approval), a tick
  # once it is confirmed, a cross when it will not go ahead.
  defp payment_status(outcome) when outcome in [:loading, :awaiting_approval],
    do: {"hero-clock", "primary"}

  defp payment_status(:confirmed), do: {"hero-check-circle", "success"}
  defp payment_status(_failed_or_ended), do: {"hero-x-circle", "danger"}

  defp testid(theme_id, slug) when is_binary(theme_id) do
    case Catalog.id_to_key(theme_id) do
      {:ok, key} -> "#{key}-#{slug}"
      {:error, _reason} -> nil
    end
  end

  defp testid(_no_theme, _slug), do: nil
end
