defmodule TymeslotWeb.Themes.Shared.Components.ProfileIntro do
  @moduledoc """
  The organiser's introduction on the booking page: the one-line headline and
  the plain-text bio stored on their profile
  (`Tymeslot.Profiles.update_intro/2`).

  A theme that presents the organiser renders `headline/1` and `bio/1` where
  its layout wants them, passing `@organizer_profile`, and styles the classes
  below; Quill and Rhythm do not use them. Each renders nothing when its field
  is empty, so a theme needs no guard of its own.

  The text is the organiser's own and reaches the page escaped. The bio's line
  breaks are its only formatting: a blank line starts a new paragraph
  (`p.profile-intro__paragraph` inside `div.profile-intro__bio`) and a single
  line break becomes a `<br>`; nothing else in the text is interpreted. The
  headline is a `p.profile-intro__headline`.

  The profile may be a `ProfileSchema` or the plain map a demo persona is,
  which may lack the fields, so they are read with `Map.get/2`.
  """
  use Phoenix.Component

  attr :profile, :map, default: nil, doc: "the organiser's profile (`@organizer_profile`)"
  attr :class, :any, default: nil

  @spec headline(map()) :: Phoenix.LiveView.Rendered.t()
  def headline(assigns) do
    assigns = assign(assigns, :text, text(assigns.profile, :headline))

    ~H"""
    <p :if={@text} class={["profile-intro__headline", @class]} data-testid="profile-headline">
      {@text}
    </p>
    """
  end

  attr :profile, :map, default: nil, doc: "the organiser's profile (`@organizer_profile`)"
  attr :class, :any, default: nil

  @spec bio(map()) :: Phoenix.LiveView.Rendered.t()
  def bio(assigns) do
    assigns = assign(assigns, :paragraphs, paragraphs(text(assigns.profile, :bio)))

    ~H"""
    <div :if={@paragraphs != []} class={["profile-intro__bio", @class]} data-testid="profile-bio">
      <p :for={lines <- @paragraphs} class="profile-intro__paragraph">
        <%= for {line, index} <- Enum.with_index(lines) do %>
          <br :if={index > 0} />{line}
        <% end %>
      </p>
    </div>
    """
  end

  defp text(nil, _field), do: nil

  defp text(profile, field) when is_map(profile) do
    case Map.get(profile, field) do
      value when is_binary(value) -> presence(String.trim(value))
      _absent -> nil
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  # A blank line (spaces allowed) separates paragraphs; within one, every
  # remaining line is kept and blank ones are dropped. The stored bio already
  # uses "\n" only (`ProfileSchema.intro_changeset/2`); a demo persona's may not.
  defp paragraphs(nil), do: []

  defp paragraphs(text) do
    text
    |> String.replace(~r/\r\n?/, "\n")
    |> String.split(~r/\n[ \t]*\n/)
    |> Enum.map(&lines/1)
    |> Enum.reject(&(&1 == []))
  end

  defp lines(paragraph) do
    paragraph
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
