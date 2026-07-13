using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text;

namespace CtoCSharpProxyFmu;

public sealed class RequestLogHub
{
    private const int HistoryLimit = 200;
    private readonly ConcurrentDictionary<Guid, WebSocket> _clients = new();
    private readonly Queue<string> _history = new();
    private readonly object _historyLock = new();

    public void Log(string message)
    {
        var line = $"[{DateTime.Now:HH:mm:ss}] {message}";
        lock (_historyLock)
        {
            _history.Enqueue(line);
            while (_history.Count > HistoryLimit)
            {
                _history.Dequeue();
            }
        }

        foreach (var (id, socket) in _clients)
        {
            if (socket.State != WebSocketState.Open)
            {
                _clients.TryRemove(id, out _);
                continue;
            }

            _ = SendSafe(socket, line);
        }
    }

    public async Task HandleWebSocketAsync(WebSocket socket, CancellationToken cancellationToken)
    {
        var id = Guid.NewGuid();
        _clients[id] = socket;

        string[] snapshot;
        lock (_historyLock)
        {
            snapshot = _history.ToArray();
        }

        foreach (var line in snapshot)
        {
            await SendSafe(socket, line);
        }

        if (snapshot.Length == 0)
        {
            await SendSafe(socket, $"[{DateTime.Now:HH:mm:ss}] Подключено. Ожидание запросов через proxy...");
        }

        try
        {
            var buffer = new byte[256];
            while (socket.State == WebSocketState.Open && !cancellationToken.IsCancellationRequested)
            {
                var result = await socket.ReceiveAsync(buffer, cancellationToken);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    break;
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (WebSocketException)
        {
        }
        finally
        {
            _clients.TryRemove(id, out _);
            if (socket.State == WebSocketState.Open || socket.State == WebSocketState.CloseReceived)
            {
                await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None);
            }
        }
    }

    private static async Task SendSafe(WebSocket socket, string message)
    {
        try
        {
            var bytes = Encoding.UTF8.GetBytes(message);
            await socket.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None);
        }
        catch
        {
        }
    }
}
