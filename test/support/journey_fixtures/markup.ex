defmodule TymeslotWeb.Test.JourneyFixtures.Markup do
  @moduledoc """
  What the journey fixtures' moments share: the root element their
  navigator's frame expects, which navigator the page has, and whether a
  moment's answer may still be changed.

  A LiveComponent's root must be one static tag, so a moment shared by
  several fixtures renders through `moment_root/2`, which writes the root
  (an `<li>` in a transcript's list, a `<section>` otherwise, each carrying
  the moment's DOM id, `data-moment`, `data-moment-state` and `booker-card`)
  around the moment's own body.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Paged
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Transcript

  @doc "The moment's root element around `body.(assigns)`."
  @spec moment_root(map(), (map() -> Phoenix.LiveView.Rendered.t())) ::
          Phoenix.LiveView.Rendered.t()
  def moment_root(assigns, body) do
    assigns = assign(assigns, :body, body)

    if transcript?(assigns) do
      ~H"""
      <li
        id={"#{@moment}-step"}
        class="booker-card"
        data-moment={@moment}
        data-moment-state={@moment_state}
      >
        {@body.(assigns)}
      </li>
      """
    else
      ~H"""
      <section
        id={"#{@moment}-step"}
        class="booker-card"
        data-moment={@moment}
        data-moment-state={@moment_state}
      >
        {@body.(assigns)}
      </section>
      """
    end
  end

  @doc "Whether the page is a transcript."
  @spec transcript?(map()) :: boolean()
  def transcript?(%{journey: %Journey{navigator: Transcript}}), do: true
  def transcript?(_assigns), do: false

  @doc "Whether the page is paged."
  @spec paged?(map()) :: boolean()
  def paged?(%{journey: %Journey{navigator: Paged}}), do: true
  def paged?(_assigns), do: false

  @doc """
  Whether the visitor may change what the moment collected
  (`Journey.revisitable?/2`): not a meeting type a direct or private link
  chose, which the runtime refuses to change from an answered moment.
  """
  @spec revisitable?(map()) :: boolean()
  def revisitable?(%{journey: %Journey{} = journey, moment: key} = assigns),
    do: Journey.revisitable?(Journey.moment(journey, key), assigns)
end
