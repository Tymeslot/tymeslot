defmodule TymeslotWeb.ContactLive do
  use TymeslotWeb, :live_view

  alias Tymeslot.Contact
  alias Tymeslot.Infrastructure.Security.RecaptchaHelpers
  alias TymeslotWeb.Components.SiteComponents
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Shared.LiveHelpers

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:page_title, "Contact Us")
      |> assign(
        :meta_description,
        "Get in touch with Tymeslot - Professional meeting scheduling platform"
      )
      |> assign(:form, to_form(%{"name" => "", "email" => "", "subject" => "", "message" => ""}))
      |> assign(:submitted, false)
      |> assign(:client_ip, ClientIP.get(socket))
      |> LiveHelpers.assign_current_user(session)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"contact" => contact_params}, socket) do
    case Contact.validate_form_input(contact_params, socket.assigns.client_ip) do
      {:ok, _sanitized_params} ->
        form = to_form(contact_params)
        {:noreply, assign(socket, :form, form)}

      {:error, errors} ->
        form = to_form(contact_params, errors: Enum.to_list(errors))
        {:noreply, assign(socket, :form, form)}
    end
  end

  @impl true
  def handle_event("submit", %{"contact" => contact_params}, socket) do
    recaptcha_token = Map.get(contact_params, "g-recaptcha-response", "")
    client_ip = socket.assigns.client_ip

    case Contact.submit_contact_form(contact_params, recaptcha_token, client_ip) do
      {:ok, _job} ->
        socket =
          socket
          |> put_flash(:info, "Thank you for your message! We'll get back to you soon.")
          |> assign(:submitted, true)
          |> assign(
            :form,
            to_form(%{"name" => "", "email" => "", "subject" => "", "message" => ""})
          )

        {:noreply, socket}

      {:error, :recaptcha_failed} ->
        socket = put_flash(socket, :error, "Security verification failed. Please try again.")
        {:noreply, socket}

      {:error, :invalid_input, _errors} ->
        socket = put_flash(socket, :error, "Please fill in all required fields.")
        {:noreply, socket}

      {:error, :rate_limited, message} ->
        socket = put_flash(socket, :error, message)
        {:noreply, socket}

      {:error, _reason} ->
        socket = put_flash(socket, :error, "An error occurred. Please try again later.")
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-gray-50 via-white to-gray-100">
      <!-- Navigation -->
      <SiteComponents.navigation current_user={@current_user} />
      
    <!-- Contact Section -->
      <section class="py-12">
        <div class="container mx-auto px-6">
          <!-- Header -->
          <div class="text-center mb-12">
            <h1 class="text-3xl md:text-4xl font-bold text-gray-800 mb-3">
              Contact Us
            </h1>
            <p class="text-lg text-gray-600 max-w-2xl mx-auto">
              Have questions about Tymeslot? Send us a message and we'll respond as soon as possible.
            </p>
          </div>

          <div class="max-w-3xl mx-auto">
            <!-- Contact Form -->
            <div class="glass-card p-6">
              <div class="mb-6">
                <div class="flex items-center justify-between mb-4">
                  <h2 class="text-xl font-bold text-gray-800">Send us a Message</h2>
                  
    <!-- Company Information - Compact -->
                  <div class="flex items-center space-x-3 text-sm">
                    <div
                      class="flex-shrink-0 w-8 h-8 turquoise-glow rounded-lg flex items-center justify-center"
                      style="background: var(--glass-gradient-primary);"
                    >
                      <svg
                        class="w-4 h-4 text-white"
                        fill="none"
                        stroke="currentColor"
                        viewBox="0 0 24 24"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"
                        />
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M15 11a3 3 0 11-6 0 3 3 0 016 0z"
                        />
                      </svg>
                    </div>
                    <div>
                      <div class="font-semibold text-gray-800">Diletta Luna OÜ</div>
                      <div class="text-gray-600">Sepapaja 6, 15551 Tallinn, Estonia</div>
                    </div>
                  </div>
                </div>
              </div>

              <.form
                :if={!@submitted}
                for={@form}
                as={:contact}
                phx-change="validate"
                phx-submit="submit"
                class="space-y-2"
                data-site-key={RecaptchaHelpers.site_key()}
                phx-hook="RecaptchaV3"
                id="contact-form"
              >
                <!-- Name and Email - Two columns on larger screens -->
                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div class="form-group mb-2">
                    <label
                      for="contact_name"
                      class="label"
                      style="color: #1f2937 !important; margin-bottom: 4px;"
                    >
                      Name *
                    </label>
                    <input
                      name="contact[name]"
                      id="contact_name"
                      type="text"
                      class="input"
                      placeholder="Your full name"
                      value={@form[:name].value}
                    />
                    <%= if @form[:name].errors != [] do %>
                      <%= for {msg, _} <- @form[:name].errors do %>
                        <div class="form-error">{msg}</div>
                      <% end %>
                    <% end %>
                  </div>

                  <div class="form-group mb-2">
                    <label
                      for="contact_email"
                      class="label"
                      style="color: #1f2937 !important; margin-bottom: 4px;"
                    >
                      Email *
                    </label>
                    <input
                      name="contact[email]"
                      id="contact_email"
                      type="email"
                      class="input"
                      placeholder="your@email.com"
                      value={@form[:email].value}
                    />
                    <%= if @form[:email].errors != [] do %>
                      <%= for {msg, _} <- @form[:email].errors do %>
                        <div class="form-error">{msg}</div>
                      <% end %>
                    <% end %>
                  </div>
                </div>

                <div class="form-group mb-2">
                  <label
                    for="contact_subject"
                    class="label"
                    style="color: #1f2937 !important; margin-bottom: 4px;"
                  >
                    Subject *
                  </label>
                  <input
                    name="contact[subject]"
                    id="contact_subject"
                    type="text"
                    class="input"
                    placeholder="What's this about?"
                    value={@form[:subject].value}
                  />
                  <%= if @form[:subject].errors != [] do %>
                    <%= for {msg, _} <- @form[:subject].errors do %>
                      <div class="form-error">{msg}</div>
                    <% end %>
                  <% end %>
                </div>

                <div class="form-group mb-2">
                  <label
                    for="contact_message"
                    class="label"
                    style="color: #1f2937 !important; margin-bottom: 4px;"
                  >
                    Message *
                  </label>
                  <textarea
                    name="contact[message]"
                    id="contact_message"
                    rows="4"
                    class="textarea"
                    placeholder="Tell us more about your inquiry..."
                  ><%= @form[:message].value %></textarea>
                  <%= if @form[:message].errors != [] do %>
                    <%= for {msg, _} <- @form[:message].errors do %>
                      <div class="form-error">{msg}</div>
                    <% end %>
                  <% end %>
                </div>
                
    <!-- Hidden reCAPTCHA field -->
                <input
                  type="hidden"
                  name="contact[g-recaptcha-response]"
                  id="g-recaptcha-response"
                  value=""
                />

                <div>
                  <button type="submit" class="btn btn-primary w-full">
                    Send Message
                  </button>
                </div>
                
    <!-- reCAPTCHA Disclaimer -->
                <div class="text-xs text-gray-500 text-center">
                  This site is protected by reCAPTCHA and the Google
                  <a
                    href="https://policies.google.com/privacy"
                    target="_blank"
                    class="turquoise-accent underline hover:text-turquoise-700"
                  >
                    Privacy Policy
                  </a>
                  and
                  <a
                    href="https://policies.google.com/terms"
                    target="_blank"
                    class="turquoise-accent underline hover:text-turquoise-700"
                  >
                    Terms of Service
                  </a>
                  apply.
                </div>
              </.form>
              
    <!-- Success Message -->
              <div :if={@submitted} class="text-center py-6">
                <div
                  class="w-12 h-12 rounded-full flex items-center justify-center mx-auto mb-3 turquoise-glow"
                  style="background: var(--color-success);"
                >
                  <svg
                    class="w-6 h-6 text-white"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M5 13l4 4L19 7"
                    />
                  </svg>
                </div>
                <h3 class="text-lg font-semibold text-gray-800 mb-2">Message Sent!</h3>
                <p class="text-gray-600">Thank you for reaching out. We'll get back to you soon.</p>
              </div>
            </div>
          </div>
        </div>
      </section>
      
    <!-- Footer -->
      <SiteComponents.site_footer />
    </div>
    """
  end
end
