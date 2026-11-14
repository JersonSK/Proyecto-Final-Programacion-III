defmodule EmergenciasWeb.AccesoLive do
  @moduledoc """
  Página de acceso. Igual que el menú de la consola, reconoce al escribir el
  usuario si ya está registrado: a un usuario existente solo le pide la contraseña
  y a uno nuevo los datos de registro (`connect` con registro automático).

  Cuando los datos son válidos, el formulario se envía a `SesionController`, que
  guarda el usuario en la cookie y lleva al panel.
  """

  use Phoenix.LiveView

  alias Emergencias.CLI.Formato
  alias Emergencias.DatosIniciales

  @tipos ~w(ciudadano voluntario coordinador administrador)

  @impl true
  def mount(_params, session, socket) do
    if session["usuario"] do
      {:ok, push_navigate(socket, to: "/panel")}
    else
      {:ok,
       socket
       |> assign(
         page_title: "Acceso",
         form: to_form(%{}, as: :acceso),
         registrado: nil,
         usuario_consultado: "",
         error: Phoenix.Flash.get(socket.assigns.flash, :error),
         enviar: false,
         tipos: @tipos,
         zonas: zonas(),
         usuarios_muestra: DatosIniciales.usuarios()
       )}
    end
  end

  @impl true
  def handle_event("cambiar", %{"acceso" => params}, socket) do
    usuario = params |> Map.get("usuario", "") |> String.trim()

    socket =
      if usuario != socket.assigns.usuario_consultado do
        registrado = if usuario == "", do: nil, else: Emergencias.usuario_registrado?(usuario)
        assign(socket, registrado: registrado, usuario_consultado: usuario)
      else
        socket
      end

    {:noreply, assign(socket, form: to_form(params, as: :acceso), error: nil)}
  end

  def handle_event("entrar", %{"acceso" => params}, socket) do
    usuario = String.trim(params["usuario"] || "")
    clave = params["clave"] || ""

    resultado =
      if Emergencias.usuario_registrado?(usuario) do
        Emergencias.autenticar(usuario, clave)
      else
        Emergencias.autenticar(
          usuario,
          clave,
          vacio_a_nil(params["tipo"]),
          vacio_a_nil(params["zona"]),
          vacio_a_nil(params["nombre"])
        )
      end

    case resultado do
      # Datos válidos: el formulario se reenvía al controlador (phx-trigger-action).
      {:ok, _usuario, _modo} ->
        {:noreply, assign(socket, form: to_form(params, as: :acceso), enviar: true)}

      {:error, motivo} ->
        {:noreply,
         assign(socket, form: to_form(params, as: :acceso), error: Formato.mensaje_error(motivo))}
    end
  end

  defp vacio_a_nil(nil), do: nil

  defp vacio_a_nil(texto) do
    case String.trim(texto) do
      "" -> nil
      valor -> valor
    end
  end

  defp zonas do
    Emergencias.Servidores.Zonas.arbol()
    |> Emergencias.Dominio.Zona.aplanar()
    |> Enum.map(fn {_profundidad, nodo} -> {nodo.codigo, nodo.nombre} end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="acceso">
      <section class="acceso-tarjeta">
        <div class="marca">
          <span class="marca-icono" aria-hidden="true">✚</span>
          <div>
            <h1>Sistema de Gestión de Emergencias</h1>
            <p class="tenue">Proyecto Final - Programación III</p>
          </div>
        </div>

        <.form
          for={@form}
          action="/entrar"
          id="formulario-acceso"
          phx-change="cambiar"
          phx-submit="entrar"
          phx-trigger-action={@enviar}
          class="formulario"
        >
          <label>
            Usuario
            <input
              type="text"
              name={@form[:usuario].name}
              value={@form[:usuario].value}
              autocomplete="username"
              phx-debounce="300"
              autofocus
              required
            />
          </label>

          <p :if={@registrado == true} class="aviso aviso-info">
            Usuario <strong>{@usuario_consultado}</strong> registrado. Ingrese su contraseña.
          </p>
          <p :if={@registrado == false} class="aviso aviso-nuevo">
            <strong>{@usuario_consultado}</strong> no existe: se creará una cuenta nueva.
          </p>

          <label>
            {if @registrado == false,
              do: "Elija una contraseña (mínimo 4 caracteres)",
              else: "Contraseña"}
            <input
              type="password"
              name={@form[:clave].name}
              value={@form[:clave].value}
              autocomplete={if @registrado == false, do: "new-password", else: "current-password"}
              required
            />
          </label>

          <div :if={@registrado == false} class="registro">
            <label>
              Tipo de usuario
              <select name={@form[:tipo].name} required>
                <option value="">Elija…</option>
                <option :for={tipo <- @tipos} value={tipo} selected={@form[:tipo].value == tipo}>
                  {String.capitalize(tipo)}
                </option>
              </select>
            </label>
            <label>
              Zona principal <span class="tenue">(opcional)</span>
              <select name={@form[:zona].name}>
                <option value="">Sin zona</option>
                <option
                  :for={{codigo, nombre} <- @zonas}
                  value={codigo}
                  selected={@form[:zona].value == codigo}
                >
                  {nombre} ({codigo})
                </option>
              </select>
            </label>
            <label>
              Nombre completo <span class="tenue">(opcional)</span>
              <input type="text" name={@form[:nombre].name} value={@form[:nombre].value} />
            </label>
          </div>

          <p :if={@error} class="aviso aviso-error" role="alert">{@error}</p>

          <button type="submit" class="boton boton-primario boton-ancho">
            {if @registrado == false, do: "Crear cuenta y entrar", else: "Entrar"}
          </button>
        </.form>

        <details class="muestra">
          <summary>Usuarios de muestra</summary>
          <p class="tenue">Todos con la contraseña <code>0000</code>:</p>
          <ul>
            <li :for={{usuario, tipo} <- @usuarios_muestra}>
              <code>{usuario}</code> — {tipo}
            </li>
          </ul>
        </details>
      </section>
    </main>
    """
  end
end
