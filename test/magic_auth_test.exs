defmodule MagicAuthTest do
  use MagicAuth.ConnCase, async: false

  import Mox

  require Phoenix.LiveView
  alias MagicAuth.{OneTimePassword, Session}

  setup :verify_on_exit!

  doctest MagicAuth, except: [create_one_time_password: 1]

  setup do
    Application.put_env(:magic_auth, :otp_app, :magic_auth_test)
    Application.put_env(:magic_auth_test, :ecto_repos, [MagicAuthTest.Repo])
    Application.put_env(:magic_auth, :callbacks, MagicAuth.CallbacksMock)
    Application.put_env(:magic_auth, :enable_rate_limit, false)

    Mox.stub(MagicAuth.CallbacksMock, :one_time_password_requested, fn _code, _one_time_password -> :ok end)
    Mox.stub(MagicAuth.CallbacksMock, :log_in_requested, fn _email -> :allow end)

    on_exit(fn ->
      Application.delete_env(:magic_auth, :otp_app)
      Application.delete_env(:magic_auth_test, :ecto_repos)
      Application.delete_env(:magic_auth, :callbacks)
      Application.delete_env(:magic_auth, :enable_rate_limit)
    end)

    conn =
      build_conn()
      |> Map.put(:secret_key_base, MagicAuthTestWeb.Endpoint.config(:secret_key_base))
      |> put_private(:phoenix_endpoint, MagicAuthTestWeb.Endpoint)
      |> Plug.Test.init_test_session(%{})

    email = "user@example.com"

    %{conn: conn, email: email}
  end

  describe "create_one_time_password/1" do
    test "generates valid one-time password with valid email" do
      email = "user@example.com"
      {:ok, {_code, token}} = MagicAuth.create_one_time_password(%{"email" => email})

      assert token.email == email
      assert String.length(token.hashed_password) > 0
    end

    test "returns error with invalid email" do
      {:error, changeset} = MagicAuth.create_one_time_password(%{"email" => "invalid_email"})
      assert "has invalid format" in errors_on(changeset).email
    end

    test "removes existing tokens before creating a new one" do
      email = "user@example.com"
      {:ok, {_code1, _token1}} = MagicAuth.create_one_time_password(%{"email" => email})
      {:ok, {_code2, token2}} = MagicAuth.create_one_time_password(%{"email" => email})

      tokens = MagicAuthTest.Repo.all(OneTimePassword)
      assert length(tokens) == 1
      assert List.first(tokens).id == token2.id
    end

    test "does not remove one-time passwords from other emails" do
      email1 = "user1@example.com"
      email2 = "user2@example.com"

      {:ok, {_code1, one_time_password1}} = MagicAuth.create_one_time_password(%{"email" => email1})
      {:ok, {_code2, one_time_password2}} = MagicAuth.create_one_time_password(%{"email" => email2})
      {:ok, {_code3, new_one_time_password1}} = MagicAuth.create_one_time_password(%{"email" => email1})

      one_time_passwords = MagicAuthTest.Repo.all(OneTimePassword)
      assert length(one_time_passwords) == 2
      assert Enum.any?(one_time_passwords, fn s -> s.id == one_time_password2.id end)
      assert Enum.any?(one_time_passwords, fn s -> s.id == new_one_time_password1.id end)
      refute Enum.any?(one_time_passwords, fn s -> s.id == one_time_password1.id end)
    end

    test "stores token value as bcrypt hash" do
      {:ok, {_code, token}} = MagicAuth.create_one_time_password(%{"email" => "user@example.com"})

      # Verify hashed_password starts with "$2b$" which is the bcrypt hash identifier
      assert String.starts_with?(token.hashed_password, "$2b$")
      # Verify hashed_password length is correct (60 characters)
      assert String.length(token.hashed_password) == 60
    end

    test "calls one_time_password_requested callback" do
      email = "user@example.com"

      expect(MagicAuth.CallbacksMock, :one_time_password_requested, fn _code, on_time_password ->
        assert on_time_password.email == email
        :ok
      end)

      {:ok, {_code, _token}} = MagicAuth.create_one_time_password(%{"email" => email})
    end

    test "returns error when rate limit is reached" do
      start_supervised!(MagicAuth.TokenBuckets.OneTimePasswordRequestTokenBucket)
      Application.put_env(:magic_auth, :enable_rate_limit, true)

      email = "user@example.com"

      assert {:ok, {_code, _token}} = MagicAuth.create_one_time_password(%{"email" => email})
      assert {:error, :rate_limited} = MagicAuth.create_one_time_password(%{"email" => email})

      Application.delete_env(:magic_auth, :enable_rate_limit)
      stop_supervised!(MagicAuth.TokenBuckets.OneTimePasswordRequestTokenBucket)
    end
  end

  describe "verify_password/2" do
    test "returns ok when password is correct and within expiration time" do
      email = "test@example.com"
      # assuming one_time_password_length is 6
      password = "123456"
      hashed_password = Bcrypt.hash_pwd_salt(password)

      # Create a valid one_time_password
      one_time_password =
        %OneTimePassword{
          email: email,
          hashed_password: hashed_password,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
        |> MagicAuth.Config.repo_module().insert!()

      assert {:ok, returned_one_time_password} = MagicAuth.verify_password(email, password)
      assert returned_one_time_password.id == one_time_password.id
    end

    test "returns error when password is expired" do
      email = "test@example.com"
      password = "123456"
      hashed_password = Bcrypt.hash_pwd_salt(password)

      # Create a one_time_password with old timestamp
      expired_time =
        DateTime.utc_now()
        # 11 minutes in the past
        |> DateTime.add(-11, :minute)
        |> DateTime.truncate(:second)

      %OneTimePassword{
        email: email,
        hashed_password: hashed_password,
        inserted_at: expired_time
      }
      |> MagicAuth.Config.repo_module().insert!()

      assert {:error, :code_expired} = MagicAuth.verify_password(email, password)
    end

    test "returns ok when password is within custom expiration time" do
      email = "test@example.com"
      password = "123456"
      hashed_password = Bcrypt.hash_pwd_salt(password)

      # Configura tempo de expiração para 50 minutos
      Application.put_env(:magic_auth, :one_time_password_expiration, 50)

      # Cria uma sessão com timestamp de 45 minutos atrás
      past_time =
        DateTime.utc_now()
        |> DateTime.add(-45, :minute)
        |> DateTime.truncate(:second)

      one_time_password =
        %OneTimePassword{
          email: email,
          hashed_password: hashed_password,
          inserted_at: past_time
        }
        |> MagicAuth.Config.repo_module().insert!()

      assert {:ok, returned_one_time_password} = MagicAuth.verify_password(email, password)
      assert returned_one_time_password.id == one_time_password.id

      # Restaura configuração padrão
      Application.put_env(:magic_auth, :one_time_password_expiration, 10)
    end

    test "returns error when password is incorrect" do
      email = "test@example.com"
      correct_password = "123456"
      wrong_password = "654321"
      hashed_password = Bcrypt.hash_pwd_salt(correct_password)

      # Create a valid one_time_password
      %OneTimePassword{
        email: email,
        hashed_password: hashed_password,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }
      |> MagicAuth.Config.repo_module().insert!()

      assert {:error, :invalid_code} = MagicAuth.verify_password(email, wrong_password)
    end

    test "returns error when email does not exist" do
      assert {:error, :invalid_code} = MagicAuth.verify_password("nonexistent@example.com", "123456")
    end
  end

  describe "one_time_password_length/0" do
    test "verifies default password length of 8 digits" do
      # Configure password length to 8 digits
      Application.put_env(:magic_auth, :one_time_password_length, 8)

      email = "test@example.com"
      password = "12345678"
      hashed_password = Bcrypt.hash_pwd_salt(password)

      one_time_password =
        %OneTimePassword{
          email: email,
          hashed_password: hashed_password,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
        |> MagicAuth.Config.repo_module().insert!()

      assert {:ok, returned_one_time_password} = MagicAuth.verify_password(email, password)
      assert returned_one_time_password.id == one_time_password.id

      # Restore default configuration
      Application.put_env(:magic_auth, :one_time_password_length, 6)
    end
  end

  describe "log_in/2" do
    setup do
      Application.put_env(:magic_auth, :router, MagicAuthTestWeb.Router)

      on_exit(fn ->
        Application.delete_env(:magic_auth, :repo)
      end)
    end

    test "returns conn", %{conn: conn} do
      conn = MagicAuth.log_in(conn, "user@example.com")
      assert %Plug.Conn{} = conn
    end

    test "stores user token in session", %{conn: conn} do
      conn = conn |> fetch_session() |> MagicAuth.log_in("user@example.com")

      assert token = get_session(conn, :session_token)
      assert get_session(conn, :live_socket_id) == "magic_auth_sessions:#{Base.url_encode64(token)}"
      assert redirected_to(conn) == "/"
      assert %Session{} = MagicAuth.get_session_by_token(token)
    end

    test "clears everything previously stored in session", %{conn: conn} do
      conn = conn |> put_session(:to_be_removed, "value") |> MagicAuth.log_in("user@example.com")
      refute get_session(conn, :to_be_removed)
    end

    test "redirects to configured path", %{conn: conn} do
      conn = conn |> put_session(:session_return_to, "/hello") |> MagicAuth.log_in("user@example.com")
      assert redirected_to(conn) == "/hello"
    end

    test "writes a cookie when remember_me is configured", %{conn: conn} do
      conn = conn |> fetch_cookies() |> MagicAuth.log_in("user@example.com")
      assert get_session(conn, :session_token) == conn.cookies[MagicAuth.Config.remember_me_cookie()]

      assert %{value: signed_token, max_age: max_age} = conn.resp_cookies[MagicAuth.Config.remember_me_cookie()]
      assert signed_token != get_session(conn, :session_token)
      # 60 dias in seconds
      assert max_age == 5_184_000
    end

    test "does not write a cookie when remember_me is not configured", %{conn: conn} do
      Application.put_env(:magic_auth, :remember_me, false)
      conn = conn |> fetch_cookies() |> MagicAuth.log_in("user@example.com")
      refute conn.resp_cookies[MagicAuth.Config.remember_me_cookie()]
      Application.put_env(:magic_auth, :remember_me, true)
    end

    test "changes session validity to 90 days", %{conn: conn} do
      Application.put_env(:magic_auth, :session_validity_in_days, 90)
      conn = conn |> fetch_cookies() |> MagicAuth.log_in("user@example.com")

      assert %{max_age: max_age} = conn.resp_cookies[MagicAuth.Config.remember_me_cookie()]
      # 90 days in seconds
      assert max_age == 7_776_000

      Application.put_env(:magic_auth, :session_validity_in_days, 60)
    end

    test "redirects to signed_in when log_in_requested returns :allow", %{conn: conn} do
      email = "user@example.com"

      Mox.expect(MagicAuth.CallbacksMock, :log_in_requested, fn ^email -> :allow end)

      conn = MagicAuth.log_in(conn, email)

      assert redirected_to(conn) == "/"
      assert get_session(conn, :session_token)
    end

    test "redirects to log_in when log_in_requested returns :deny", %{conn: conn} do
      email = "blocked@example.com"

      Mox.expect(MagicAuth.CallbacksMock, :log_in_requested, fn ^email -> :deny end)
      Mox.expect(MagicAuth.CallbacksMock, :translate_error, fn :access_denied -> "Access denied" end)

      conn = conn |> fetch_flash() |> MagicAuth.log_in(email)

      assert redirected_to(conn) == MagicAuth.Config.router().__magic_auth__(:log_in)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Access denied"
      refute get_session(conn, :session_token)
    end
  end

  describe "get_session_by_token/1" do
    test "returns the session when token is valid", %{conn: conn} do
      email = "user@example.com"
      conn = MagicAuth.log_in(conn, email)
      token = get_session(conn, :session_token)

      assert session = MagicAuth.get_session_by_token(token)
      assert session.email == email
    end

    test "returns nil when token is invalid" do
      assert MagicAuth.get_session_by_token("invalid_token") == nil
    end

    test "returns nil when token is expired", %{conn: conn} do
      email = "user@example.com"
      conn = MagicAuth.log_in(conn, email)
      token = get_session(conn, :session_token)

      # Simulate a future date beyond validity period
      expired_days = -(MagicAuth.Config.session_validity_in_days() + 1)
      expired_date = DateTime.utc_now() |> DateTime.add(expired_days, :day) |> DateTime.truncate(:second)

      # Update session insertion date
      session = MagicAuth.get_session_by_token(token)

      Ecto.Changeset.change(session, inserted_at: expired_date)
      |> MagicAuth.Config.repo_module().update!()

      assert MagicAuth.get_session_by_token(token) == nil
    end
  end

  describe "log_out/1" do
    test "erases session and cookies", %{conn: conn, email: email} do
      session = MagicAuth.create_session!(email)
      session_token = session.token

      conn =
        conn
        |> put_session(:session_token, session_token)
        |> put_req_cookie(MagicAuth.Config.remember_me_cookie(), session_token)
        |> fetch_cookies()
        |> MagicAuth.log_out()

      refute get_session(conn, :session_token)
      refute conn.cookies[MagicAuth.Config.remember_me_cookie()]
      assert %{max_age: 0} = conn.resp_cookies[MagicAuth.Config.remember_me_cookie()]
      assert redirected_to(conn) == "/"
      refute MagicAuth.get_session_by_token(session_token)
    end

    test "works even if user is already logged out", %{conn: conn} do
      conn = conn |> fetch_cookies() |> MagicAuth.log_out()
      refute get_session(conn, :session_token)
      assert %{max_age: 0} = conn.resp_cookies[MagicAuth.Config.remember_me_cookie()]
      assert redirected_to(conn) == "/"
    end
  end

  describe "session authentication" do
    test "fetch_current_user_session returns nil when there is no token", %{conn: conn} do
      conn = MagicAuth.fetch_current_user_session(conn, [])
      assert conn.assigns.current_user_session == nil
    end

    test "fetch_current_user_session loads session when token is valid", %{conn: conn} do
      email = "test@example.com"
      session = MagicAuth.create_session!(email)

      conn =
        conn
        |> put_session(:session_token, session.token)
        |> MagicAuth.fetch_current_user_session([])

      assert %Session{email: ^email} = conn.assigns.current_user_session
    end
  end

  describe "require_authenticated/2" do
    test "redirects when not authenticated", %{conn: conn} do
      Mox.expect(MagicAuth.CallbacksMock, :translate_error, fn :unauthorized ->
        "You must log in to access this page."
      end)

      conn = conn |> fetch_flash() |> MagicAuth.require_authenticated([])

      assert conn.halted
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "You must log in to access this page."
      assert redirected_to(conn) == MagicAuth.Config.router().__magic_auth__(:log_in)
    end

    test "allows access when authenticated", %{conn: conn} do
      email = "test@example.com"
      session = MagicAuth.create_session!(email)

      conn =
        conn
        |> put_session(:session_token, session.token)
        |> assign(:current_user_session, %Session{email: email})
        |> MagicAuth.require_authenticated([])

      refute conn.halted
    end
  end

  describe "fetch_current_user_session/2" do
    test "loads session from session token when there is no remember_me cookie", %{conn: conn} do
      email = "test@example.com"
      session = MagicAuth.create_session!(email)

      conn =
        conn
        |> put_session(:session_token, session.token)
        |> MagicAuth.fetch_current_user_session([])

      assert %Session{email: ^email} = conn.assigns.current_user_session
    end

    test "loads session from remember_me cookie when there is no session token", %{conn: conn} do
      email = "test@example.com"

      conn = MagicAuth.log_in(conn, email)
      conn = MagicAuth.fetch_current_user_session(conn, [])

      assert %Session{email: ^email} = conn.assigns.current_user_session
    end

    test "returns nil when there is no session token and no remember_me cookie", %{conn: conn} do
      conn = MagicAuth.fetch_current_user_session(conn, [])

      assert conn.assigns.current_user_session == nil
    end

    test "returns nil when remember_me cookie token is invalid", %{conn: conn} do
      conn =
        conn
        |> put_resp_cookie(MagicAuth.Config.remember_me_cookie(), "invalid_token", MagicAuth.remember_me_options())
        |> MagicAuth.fetch_current_user_session([])

      assert conn.assigns.current_user_session == nil
    end
  end

  describe "redirect_if_authenticated/2" do
    test "redirects when authenticated", %{conn: conn} do
      conn =
        conn
        |> assign(:current_user_session, %Session{email: "test@example.com"})
        |> MagicAuth.redirect_if_authenticated([])

      assert conn.halted
      assert redirected_to(conn) == MagicAuth.Config.router().__magic_auth__(:signed_in)
    end
  end

  describe "on_mount :mount_current_user_session" do
    test "assigns nil when there is no token" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{}

      assert {:cont, socket} = MagicAuth.on_mount(:mount_current_user_session, %{}, session, socket)
      assert socket.assigns.current_user_session == nil
    end

    test "loads session when token is valid" do
      socket = %Phoenix.LiveView.Socket{}
      email = "test@example.com"
      session = MagicAuth.create_session!(email)
      session_data = %{"session_token" => session.token}

      assert {:cont, socket} = MagicAuth.on_mount(:mount_current_user_session, %{}, session_data, socket)
      assert %Session{email: ^email} = socket.assigns.current_user_session
    end
  end

  describe "on_mount :require_authenticated" do
    test "redirects when not authenticated" do
      Mox.expect(MagicAuth.CallbacksMock, :translate_error, fn :unauthorized ->
        "You must log in to access this page."
      end)

      socket = %Phoenix.LiveView.Socket{}
      socket = Map.put(socket, :assigns, Map.put(socket.assigns || %{}, :flash, %{}))
      session = %{}

      assert {:halt, socket} = MagicAuth.on_mount(:require_authenticated, %{}, session, socket)
      assert socket.assigns.current_user_session == nil
      assert socket.redirected == {:redirect, %{to: MagicAuth.Config.router().__magic_auth__(:log_in), status: 302}}
      assert Phoenix.Flash.get(socket.assigns.flash, :error) == "You must log in to access this page."
    end

    test "allows access when authenticated" do
      socket = %Phoenix.LiveView.Socket{}
      email = "test@example.com"
      session = MagicAuth.create_session!(email)
      session_data = %{"session_token" => session.token}

      assert {:cont, socket} = MagicAuth.on_mount(:require_authenticated, %{}, session_data, socket)
      assert %Session{email: ^email} = socket.assigns.current_user_session
    end
  end

  describe "on_mount :redirect_if_authenticated" do
    test "redirects when authenticated" do
      socket = %Phoenix.LiveView.Socket{}
      email = "test@example.com"
      session = MagicAuth.create_session!(email)
      session_data = %{"session_token" => session.token}

      assert {:halt, socket} = MagicAuth.on_mount(:redirect_if_authenticated, %{}, session_data, socket)
      assert socket.redirected == {:redirect, %{to: MagicAuth.Config.router().__magic_auth__(:signed_in), status: 302}}
    end

    test "allows access when not authenticated" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{}

      assert {:cont, socket} = MagicAuth.on_mount(:redirect_if_authenticated, %{}, session, socket)
      assert socket.assigns.current_user_session == nil
    end
  end

  describe "delete_all_sessions_by_token/1" do
    test "removes the session", %{conn: conn} do
      email = "test@example.com"
      session = MagicAuth.create_session!(email)

      assert :ok = MagicAuth.delete_all_sessions_by_token(session.token)

      conn =
        conn
        |> put_session(:session_token, session.token)
        |> MagicAuth.fetch_current_user_session([])

      assert conn.assigns.current_user_session == nil
    end
  end

  describe "delete_all_sessions_by_email/1" do
    test "deletes all sessions for a given email" do
      email = "user@example.com"

      session1 = MagicAuth.create_session!(email)
      session2 = MagicAuth.create_session!(email)
      other_session = MagicAuth.create_session!("other@example.com")

      assert {2, nil} = MagicAuth.delete_all_sessions_by_email(email)

      assert is_nil(MagicAuth.get_session_by_token(session1.token))
      assert is_nil(MagicAuth.get_session_by_token(session2.token))

      assert MagicAuth.get_session_by_token(other_session.token)
    end

    test "returns {0, nil} when no sessions exist for the email" do
      assert {0, nil} = MagicAuth.delete_all_sessions_by_email("nonexistent@example.com")
    end
  end
end
