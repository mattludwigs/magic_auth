# 🔒 Magic Auth

Magic Auth is an authentication library for Phoenix that provides effortless configuration and flexibility for your project.

![Magic Auth in action](assets/magic_auth_in_action.gif)

## Key Features

- **Ship Faster** 🚀: No time wasted configuring password resets and recovery flows - just implement and ship your product.
- **Passwordless Authentication** 📨: Secure login process through one-time passwords sent via email. One-time passwords are better than magic links because users can receive the code on one device (e.g., phone email) and enter it on another (e.g., desktop browser).
- **Enhanced Security** 🔒: Protect your application from brute force attacks with built-in rate limiting and account lockout mechanisms.
- **Customizable Interface** 🎨: Fully customizable UI components to match your design.
- **Effortless Configuration and Comprehensive Documentation** 📚: Quick and simple integration with your Phoenix project, with detailed guides and references to assist you through every step of the integration process.
- **Schema Agnostic** 👤: Implement authentication without requiring a user schema - ideal for everything from MVPs to complex applications.

## Installation

To install Magic Auth, add it to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:magic_auth, "~> 0.1.0"}
  ]
end
```

## Getting started

Magic Auth simplifies the process of adding authentication to your Phoenix application. You'll have a fully functional authentication system integrated into your Phoenix application in less than 5 minutes. It's just 2 easy and quick steps!

### Step 1 - Run generator

After adding Magic Auth to your dependencies, you can quickly set up authentication in your Phoenix application using the installation generator:

```bash
mix magic_auth.install
```

If you are working within an umbrella project, navigate to your web application directory and run the generator:

```bash
cd apps/my_app_web/ && mix magic_auth.install
```

Don't forget to run the migrations to create the necessary tables for Magic Auth:

```bash
mix ecto.migrate
```

### Step 2 - Protect your routes

To protect your controllers and LiveViews with authentication, you need to configure the appropriate plugs and LiveView mounts. Edit the `lib/my_app_web/router.ex` file and modify it as shown in the example below:

```elixir
defmodule MyAppWeb.Router do 
  # Additional router contents...

  scope "/", MyAppWeb do
    # Add MagicAuth.require_authenticated/2 plug to protect controllers
    # and LiveView first mount (disconnected)
    pipe_through [:browser, :require_authenticated]

    get "/protected_controller", ProtectedController, :index

    # Use MagicAuth.required_authenticated/4 to protect LiveView's socket connection
    live_session :authenticated, on_mount: [{MagicAuth, :require_authenticated}] do
      live "/protected_live_view", ProtectedLiveView
    end
  end
end
```

For more details, refer to `MagicAuth.require_authenticated/2` and `MagicAuth.on_mount/4`.

## Customization
The generator will create a file at `lib/my_app_web/magic_auth.ex` (or at `apps/my_app_web/lib/my_app_web/magic_auth.ex` in an umbrella project). This file contains several callbacks that you can modify to match your application's needs. It is filled with comprehensive comments that guide you through customizing both the appearance and behavior of Magic Auth. For detailed instructions, please refer to the comments in the generated file. Below is a brief explanation of what can be customized:

- The log in form appearance by modifying `log_in_form/1`.
- The verification form appearance by modifying `verify_form/1`.
- E-mail templates by modifying `one_time_password_requested/1`, `text_email_body/1`, and `html_email_body/1`.
- Access control logic by modifying `log_in_requested/1`.
- Error message translations by modifying `translate_error/1`.