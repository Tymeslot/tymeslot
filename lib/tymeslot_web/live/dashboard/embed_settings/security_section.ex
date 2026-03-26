defmodule TymeslotWeb.Live.Dashboard.EmbedSettings.SecuritySection do
  @moduledoc """
  Renders the security settings section for the embed settings dashboard.
  """
  use TymeslotWeb, :html

  @doc """
  Renders the security settings section.
  """
  attr :allowed_domains, :list, required: true
  attr :myself, :any, required: true

  @spec security_section(map()) :: Phoenix.LiveView.Rendered.t()
  def security_section(assigns) do
    ~H"""
    <div class="bg-white rounded-token-2xl border-2 border-tymeslot-200 p-8">
      <div class="flex items-start justify-between mb-6">
        <div class="flex-1">
          <div class="flex items-center space-x-3 mb-2">
            <svg class="w-6 h-6 text-amber-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"></path>
            </svg>
            <h3 class="text-token-2xl font-bold text-tymeslot-900">Security & Domain Control</h3>
          </div>
          <p class="text-tymeslot-600">
            Control which websites can embed your booking page
          </p>
        </div>
      </div>

      <div class="space-y-6">
        <%!-- Explanation --%>
        <div class="bg-gradient-to-r from-blue-50 to-cyan-50 border-2 border-blue-200 rounded-token-xl p-6">
          <div class="flex items-start space-x-3">
            <svg class="w-6 h-6 text-blue-600 flex-shrink-0 mt-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
            </svg>
            <div class="space-y-2 text-token-sm">
              <p class="font-semibold text-blue-900">How Domain Whitelisting Works</p>
              <p class="text-blue-800">
                By default, embedding is disabled to prevent unauthorized use of your booking page.
                To enable embedding, you must specify the domains you trust.
              </p>
              <p class="text-blue-800">
                For security, <strong>you must restrict embedding</strong> to only specific domains you trust. 
                This prevents your booking page from appearing on unauthorized websites.
              </p>
              <ul class="list-disc list-inside text-blue-800 space-y-1 mt-2">
                <li><strong>Add domains</strong> to enable and restrict embedding to only those sites</li>
                <li><strong>Use Disable Embedding</strong> to block all embedding (default)</li>
                <li>
                  Adding <code class="bg-blue-100 px-2 py-0.5 rounded">example.com</code>
                  automatically allows <code class="bg-blue-100 px-2 py-0.5 rounded">www.example.com</code> too (and vice versa)
                </li>
                <li>
                  Use <code class="bg-blue-100 px-2 py-0.5 rounded">*.example.com</code> to allow all subdomains
                </li>
              </ul>
            </div>
          </div>
        </div>

        <%!-- Domain Input Form --%>
        <.form_wrapper
          for={%{}}
          id="embed-domains-form"
          phx-submit="save_embed_domains"
          phx-target={@myself}
          class="space-y-4"
        >
          <.input
            type="text"
            id="allowed_domains"
            name="allowed_domains"
            value=""
            label="Add Allowed Domain"
            placeholder="example.com"
            icon="hero-globe-alt"
          />
          <p class="mt-2 text-token-xs text-tymeslot-600">
            Enter a domain and press enter to add it. Don't include <code class="bg-tymeslot-100 px-1 py-0.5 rounded">https://</code> or paths.
          </p>

          <%!-- Current Domains Tags --%>
          <%= if @allowed_domains != [] and @allowed_domains != ["none"] do %>
            <div class="flex flex-wrap gap-2 mt-4">
              <%= for domain <- @allowed_domains do %>
                <span class="inline-flex items-center px-3 py-1 rounded-full text-sm font-medium bg-turquoise-100 text-turquoise-800 border border-turquoise-200">
                  {domain}
                  <button
                    type="button"
                    phx-click="remove_domain"
                    phx-value-domain={domain}
                    phx-target={@myself}
                    class="ml-2 inline-flex items-center p-0.5 rounded-full text-turquoise-400 hover:bg-turquoise-200 hover:text-turquoise-500 focus:outline-none"
                  >
                    <svg class="h-3 w-3" fill="currentColor" viewBox="0 0 20 20">
                      <path
                        fill-rule="evenodd"
                        d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z"
                        clip-rule="evenodd"
                      />
                    </svg>
                  </button>
                </span>
              <% end %>
            </div>
          <% end %>

          <%!-- Current Status --%>
          <div class="bg-tymeslot-50 rounded-token-lg p-4 border-2 border-tymeslot-200">
            <p class="text-token-sm font-semibold text-tymeslot-700 mb-2">Current Status:</p>
            <div class="flex items-center space-x-2">
            <%= if @allowed_domains == [] or @allowed_domains == ["none"] do %>
                <svg class="w-5 h-5 text-red-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18.364 5.636l-12.728 12.728M6.343 6.343l12.728 12.728"></path>
                </svg>
                <span class="text-token-sm text-tymeslot-700">
                  <strong>Disabled:</strong> Embedding is blocked everywhere (default)
                </span>
            <% else %>
                <svg class="w-5 h-5 text-amber-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"></path>
                </svg>
                <span class="text-token-sm text-tymeslot-700">
                  <strong>Restricted:</strong> Only your whitelisted domains can embed
                </span>
            <% end %>
            </div>
          </div>

          <%!-- Action Buttons --%>
          <div class="flex space-x-3">
            <.action_button type="submit">
              Add Domain
            </.action_button>
            <%= if @allowed_domains != ["none"] and @allowed_domains != [] do %>
              <.action_button
                variant={:secondary}
                phx-click="clear_embed_domains"
                phx-target={@myself}
              >
                Disable All Embedding
              </.action_button>
            <% end %>
          </div>
        </.form_wrapper>
      </div>
    </div>
    """
  end
end
