defmodule TymeslotWeb.Legal.TermsAndConditionsComponent do
  @moduledoc """
  LiveView component that renders the terms and conditions page with
  service descriptions, user responsibilities, and legal policies.
  """
  use TymeslotWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-4xl font-bold text-gray-900 mb-8 text-center bg-gradient-to-r from-purple-600 to-indigo-600 bg-clip-text text-transparent">
        Terms and Conditions
      </h1>

      <div class="prose prose-lg max-w-none">
        <p class="text-gray-600 mb-6">
          Last updated: 25th September 2025
        </p>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">1. Acceptance of Terms</h2>
          <p class="text-gray-700 leading-relaxed">
            By accessing and using Tymeslot, a cloud-based SaaS scheduling platform,
            you agree to be bound by these Terms and Conditions. If you do not agree
            to these terms, please do not use our service.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">2. Service Description</h2>
          <p class="text-gray-700 leading-relaxed">
            Tymeslot is an open-source, cloud-based appointment scheduling platform that enables
            users to manage meetings, integrate with multiple calendar providers, and conduct
            video conferences. The service includes:
          </p>
          <ul class="list-disc pl-6 mt-3 space-y-2 text-gray-700">
            <li>Multi-provider calendar integration (Google, Outlook, CalDAV, Nextcloud)</li>
            <li>Video conferencing with multiple providers</li>
            <li>Automated email notifications and reminders</li>
            <li>Multi-timezone support and availability management</li>
            <li>User authentication and profile management</li>
          </ul>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">3. User Responsibilities</h2>
          <p class="text-gray-700 leading-relaxed mb-3">
            As a user of Tymeslot, you agree to:
          </p>
          <ul class="list-disc pl-6 space-y-2 text-gray-700">
            <li>
              Provide accurate and complete information when creating accounts and booking appointments
            </li>
            <li>Maintain the security of your account credentials</li>
            <li>Respect scheduled meeting times and notify of cancellations promptly</li>
            <li>Use the service only for lawful purposes and in compliance with applicable laws</li>
            <li>Not attempt to disrupt, compromise, or reverse engineer the service</li>
            <li>Respect the open-source nature and community guidelines</li>
          </ul>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">4. Privacy and Data Protection</h2>
          <p class="text-gray-700 leading-relaxed">
            Your privacy is important to us. Please review our
            <.link
              href="/legal/privacy-policy"
              class="text-purple-600 hover:text-purple-800 font-medium"
            >
              Privacy Policy
            </.link>
            to understand how we collect, use, and protect your information.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">
            5. Service Availability and Support
          </h2>
          <p class="text-gray-700 leading-relaxed">
            We strive to provide reliable service but cannot guarantee 100% uptime.
            As an open-source project, community support is available through our
            public channels. Professional support may be limited.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">6. Meeting Cancellation Policy</h2>
          <p class="text-gray-700 leading-relaxed">
            Meetings can be cancelled or rescheduled based on the minimum notice settings
            configured by the meeting organizer. Both parties will receive email notifications
            of any changes according to their notification preferences.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">7. Limitation of Liability</h2>
          <p class="text-gray-700 leading-relaxed">
            Tymeslot is provided "as is" without warranties of any kind. To the maximum extent
            permitted by applicable law, we are not liable for:
          </p>
          <ul class="list-disc pl-6 mt-3 space-y-2 text-gray-700">
            <li>Meeting no-shows, scheduling conflicts, or miscommunications</li>
            <li>Technical issues affecting integrations or video quality</li>
            <li>Calendar synchronization delays or failures</li>
            <li>Data loss or service interruptions</li>
            <li>Any indirect, incidental, or consequential damages</li>
          </ul>
          <p class="text-gray-700 leading-relaxed mt-3">
            Our liability is limited to the amount paid for the service in the 12 months
            preceding the claim, where applicable.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">
            8. Intellectual Property and Open Source
          </h2>
          <p class="text-gray-700 leading-relaxed">
            Tymeslot is an open-source project. The source code is available under the Elastic License 2.0,
            which allows for use, modification, and distribution with certain limitations. While the code is open source,
            the Tymeslot brand, trademarks, and service marks remain our property.
          </p>
          <p class="text-gray-700 leading-relaxed mt-3">
            You retain ownership of any data you input into the service. By using the service,
            you grant us the necessary rights to process and store your data as described in our Privacy Policy.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">9. Modifications to Terms</h2>
          <p class="text-gray-700 leading-relaxed">
            We reserve the right to modify these terms at any time. We will notify users of any
            material changes via email or through the service, and update the "Last updated" date.
            Continued use of the service after changes constitutes acceptance of the new terms.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">10. Termination</h2>
          <p class="text-gray-700 leading-relaxed">
            Either party may terminate this agreement at any time. We may terminate or suspend
            access to our service immediately, without prior notice, for any breach of these
            Terms and Conditions. Upon termination, your data will be handled according to
            our Privacy Policy and data retention schedule.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">11. Governing Law</h2>
          <p class="text-gray-700 leading-relaxed">
            These Terms and Conditions are governed by and construed in accordance with the
            laws of the European Union and the applicable member state where the service is operated.
            Any disputes arising from these terms shall be subject to the jurisdiction of the
            competent courts in that jurisdiction.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">12. Contact Information</h2>
          <p class="text-gray-700 leading-relaxed">
            If you have any questions about these Terms and Conditions, please contact us:
          </p>
          <div class="mt-3 pl-6 text-gray-700">
            <p>
              <.link href="/contact" class="text-purple-600 hover:text-purple-800 font-medium">
                Contact Form
              </.link>
            </p>
          </div>
        </section>
      </div>
    </div>
    """
  end
end
