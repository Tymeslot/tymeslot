defmodule TymeslotWeb.Shared.Auth.FormComponents do
  @moduledoc """
  Form wrappers and form-related utilities for authentication.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents.TranslatedLink, only: [link_html: 2]

  alias Phoenix.Controller

  @spec auth_form(map()) :: Phoenix.LiveView.Rendered.t()
  def auth_form(assigns) do
    assigns =
      assigns
      |> assign_new(:method, fn -> "POST" end)
      |> assign_new(:"phx-submit", fn -> nil end)
      |> assign_new(:"phx-change", fn -> nil end)
      |> assign_new(:action, fn -> nil end)
      |> assign_new(:class, fn -> "space-y-4 mb-6" end)
      |> assign_new(:id, fn -> nil end)
      |> assign_new(:loading, fn -> false end)
      |> assign_new(:csrf_token, fn -> Controller.get_csrf_token() end)
      |> assign_new(:rest, fn -> %{} end)

    ~H"""
    <form
      id={@id}
      class={@class}
      method={@method}
      action={@action}
      phx-submit={assigns[:"phx-submit"]}
      phx-change={assigns[:"phx-change"]}
      data-loading={@loading}
      {@rest}
    >
      <%= if @action || assigns[:"phx-submit"] do %>
        <input type="hidden" name="_csrf_token" value={@csrf_token} />
      <% end %>
      {render_slot(@inner_block)}
    </form>
    """
  end

  @spec terms_checkbox(map()) :: Phoenix.LiveView.Rendered.t()
  def terms_checkbox(assigns) do
    assigns =
      assigns
      |> assign_new(:name, fn -> "user[terms_accepted]" end)
      |> assign_new(:style, fn -> :simple end)
      |> assign_new(:class, fn -> "" end)
      |> assign(:terms_url, Application.get_env(:tymeslot, :legal_terms_url))
      |> assign(:privacy_url, Application.get_env(:tymeslot, :legal_privacy_url))

    ~H"""
    <div class={["flex items-start gap-3", @class]}>
      <input
        type="checkbox"
        id="terms"
        name={@name}
        class="checkbox mt-1 w-5 h-5"
        value="true"
        required
      />
      <label for="terms" class="text-sm text-tymeslot-500 font-medium leading-relaxed">
        {raw(
          dgettext(
            "auth",
            "I accept the %{terms} and %{privacy_policy}",
            terms:
              link_html(dgettext("auth", "terms"),
                href: @terms_url,
                target: "_blank",
                class:
                  "text-turquoise-600 hover:text-turquoise-700 font-bold underline decoration-turquoise-100 underline-offset-4"
              ),
            privacy_policy:
              link_html(dgettext("auth", "privacy policy"),
                href: @privacy_url,
                target: "_blank",
                class:
                  "text-turquoise-600 hover:text-turquoise-700 font-bold underline decoration-turquoise-100 underline-offset-4"
              )
          )
        )}
      </label>
    </div>
    """
  end
end
