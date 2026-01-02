defmodule TymeslotWeb.Shared.Auth.FormComponents do
  @moduledoc """
  Form wrappers and form-related utilities for authentication.
  """

  use TymeslotWeb, :html

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
    assigns = assign_new(assigns, :name, fn -> "user[terms_accepted]" end)
    assigns = assign_new(assigns, :style, fn -> :simple end)
    assigns = assign_new(assigns, :class, fn -> "" end)

    ~H"""
    <%= if @style == :simple do %>
      <div class={"flex items-start mt-4 sm:mt-5 terms-checkbox #{@class}"}>
        <div class="flex items-center h-5">
          <input
            type="checkbox"
            id="terms"
            name={@name}
            class="h-4 w-4 text-primary-600 border-primary-300 rounded focus:ring-primary-500"
            value="true"
            required
          />
        </div>
        <div class="ml-2 sm:ml-3">
          <label for="terms" class="text-xs sm:text-sm text-gray-700">
            I accept the
            <a
              href="/legal/terms-and-conditions"
              target="_blank"
              class="text-primary-600 hover:text-primary-700 font-medium"
            >
              terms and conditions
            </a>
            and
            <a
              href="/legal/privacy-policy"
              target="_blank"
              class="text-primary-600 hover:text-primary-700 font-medium"
            >
              privacy policy
            </a>
          </label>
        </div>
      </div>
    <% else %>
      <div class={"mt-2 sm:mt-4 terms-checkbox #{@class}"}>
        <div class="flex items-start sm:items-center">
          <div class="relative mt-0.5 sm:mt-0">
            <input
              type="checkbox"
              id="terms"
              name={@name}
              class="peer h-5 w-5 sm:h-6 sm:w-6 border-2 border-gray-300 rounded focus:ring-2 focus:ring-primary-500"
              value="true"
              required
            />
          </div>
          <label for="terms" class="ml-2 text-xs sm:text-sm text-pretty text-gray-700 cursor-pointer">
            I accept the
            <a
              href="/legal/terms-and-conditions"
              target="_blank"
              class="font-medium text-primary-600 hover:text-primary-700 transition duration-300 ease-in-out"
            >
              terms and conditions
            </a>
            and <a
              href="/legal/privacy-policy"
              target="_blank"
              class="font-medium text-primary-600 hover:text-primary-700 transition duration-300 ease-in-out"
            >privacy policy</a>.
          </label>
        </div>
      </div>
    <% end %>
    """
  end

  @spec form_label(map()) :: Phoenix.LiveView.Rendered.t()
  def form_label(assigns) do
    ~H"""
    <label
      for={@for}
      class="block text-xs sm:text-sm font-medium text-gray-700 mb-1 sm:mb-2 form-label"
    >
      {@text}
    </label>
    """
  end
end
