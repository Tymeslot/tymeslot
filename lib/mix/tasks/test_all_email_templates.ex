defmodule Mix.Tasks.TestAllEmailTemplates do
  @moduledoc """
  Comprehensive test of ALL email templates in Tymeslot.
  Sends real MJML email templates through the configured email adapter.

  ## Usage
      # Send all email templates
      mix test_all_email_templates your@email.com

      # Send specific email template by number
      mix test_all_email_templates your@email.com --only 7

      # Send specific email template by name
      mix test_all_email_templates your@email.com --only email_verification

      # Send multiple specific templates
      mix test_all_email_templates your@email.com --only 1,7,10

      # List available templates
      mix test_all_email_templates --list
  """

  use Mix.Task
  require Logger

  alias Tymeslot.EmailTesting.{Dispatcher, Helpers, Registry}
  alias Tymeslot.EmailTesting.Testers.Appointment

  @shortdoc "Test email templates through configured adapter"

  @impl Mix.Task
  def run(["--list"]) do
    IO.puts("\n📧 Available Email Templates:")
    IO.puts("=" <> String.duplicate("=", 60))

    Enum.each(Registry.list_sorted(), fn {num, {key, name}} ->
      IO.puts("  #{String.pad_leading(num, 2)}: #{name}")
      IO.puts("      Key: #{key}")
    end)

    IO.puts("\n💡 Usage: mix test_all_email_templates your@email.com --only 7")
    IO.puts("         mix test_all_email_templates your@email.com --only email_verification")
  end

  def run([email]) when is_binary(email), do: run([email, "--all"])

  def run([email, "--all"]) when is_binary(email) do
    run_all(email)
  end

  def run([email, "--only", template_spec]) when is_binary(email) do
    run_only(email, template_spec)
  end

  def run(_) do
    IO.puts("""
    ❌ Invalid arguments!

    Usage:
      # Send all templates
      mix test_all_email_templates <email>

      # Send specific templates
      mix test_all_email_templates <email> --only <template_spec>

      # List available templates
      mix test_all_email_templates --list

    Examples:
      mix test_all_email_templates test@example.com
      mix test_all_email_templates test@example.com --only 7
      mix test_all_email_templates test@example.com --only email_verification
      mix test_all_email_templates test@example.com --only 1,7,10
    """)
  end

  defp run_all(email) do
    Mix.Task.run("app.start")

    config = Application.get_env(:tymeslot, Tymeslot.Mailer)
    adapter_name = Helpers.get_adapter_name(config[:adapter])

    IO.puts("\n🚀 Testing ALL Email Templates to #{email}")
    IO.puts("📧 Using adapter: #{adapter_name}")
    IO.puts("=" <> String.duplicate("=", 60))

    now = DateTime.utc_now()
    tomorrow = DateTime.add(now, 86_400, :second)
    templates_map = Registry.templates()

    # 1-6. Batch appointment tests
    batch_results = [
      Appointment.test_confirmations_both(email, tomorrow),
      Appointment.test_reminders_both(email, tomorrow),
      Appointment.test_cancellations_both(email, tomorrow)
    ]

    # Individual tests via registry (excluding batch tests 1-6)
    individual_ids =
      templates_map
      |> Map.keys()
      |> Enum.reject(&(String.to_integer(&1) in 1..6))
      |> Enum.sort_by(&String.to_integer/1)

    individual_results =
      Enum.map(individual_ids, fn id ->
        {_, result} = handle_template(id, templates_map, email, tomorrow)
        result
      end)

    results = batch_results ++ individual_results

    successful = Enum.count(results, &(&1 == :ok))
    failed = Enum.count(results, &(&1 == :error))

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("✅ Successfully sent: #{successful} email templates")
    IO.puts("❌ Failed to send: #{failed} email templates")
    IO.puts("=" <> String.duplicate("=", 60))

    if failed > 0 do
      IO.puts("\n💡 Check the error logs above for details")
    else
      IO.puts("\n🎉 All email templates sent successfully!")
    end
  end

  defp run_only(email, template_spec) do
    Mix.Task.run("app.start")

    config = Application.get_env(:tymeslot, Tymeslot.Mailer)
    adapter_name = Helpers.get_adapter_name(config[:adapter])

    templates = Registry.parse_template_spec(template_spec)

    if templates == [] do
      IO.puts("❌ No valid templates specified!")
      IO.puts("💡 Use --list to see available templates")
    else
      IO.puts("\n🚀 Testing Selected Email Templates to #{email}")
      IO.puts("📧 Using adapter: #{adapter_name}")
      IO.puts("📋 Templates: #{Enum.join(templates, ", ")}")
      IO.puts("=" <> String.duplicate("=", 60))

      now = DateTime.utc_now()
      tomorrow = DateTime.add(now, 86_400, :second)

      templates_map = Registry.templates()

      results = Enum.map(templates, &handle_template(&1, templates_map, email, tomorrow))

      successful = Enum.count(results, fn {_, result} -> result == :ok end)
      failed = Enum.count(results, fn {_, result} -> result == :error end)

      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("✅ Successfully sent: #{successful} email template(s)")
      IO.puts("❌ Failed to send: #{failed} email template(s)")
      IO.puts("=" <> String.duplicate("=", 60))

      if failed > 0 do
        IO.puts("\n💡 Check the error logs above for details")
      else
        IO.puts("\n🎉 All selected email templates sent successfully!")
      end
    end
  end

  defp handle_template(template_id, templates_map, email, tomorrow) do
    case templates_map[template_id] do
      {key, name} ->
        IO.write("📧 #{template_id}. #{name}... ")
        result = Dispatcher.test_individual_email(key, email, tomorrow)
        {template_id, result}

      nil ->
        IO.puts("❌ Template #{template_id} not found")
        {template_id, :error}
    end
  end
end
