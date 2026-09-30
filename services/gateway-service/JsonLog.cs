// 한 줄짜리 JSON 로그: {"ts","level","service","msg", ...필드}. 다른 일곱 서비스와 같은 모양으로 맞춘다.
// .NET 내장 JSON 콘솔 로거는 필드를 State 아래에 중첩해 모양이 달라서, 표준 라이브러리(System.Text.Json)로 직접 쓴다.
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Logging.Console;

static class JsonLog
{
    const string Service = "gateway-service";
    static readonly JsonWriterOptions Options = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static void Info(string msg, params (string Key, object? Value)[] fields) => Write("INFO", msg, null, fields);
    public static void Warn(string msg, params (string Key, object? Value)[] fields) => Write("WARN", msg, null, fields);
    public static void Error(string msg, Exception? e, params (string Key, object? Value)[] fields) => Write("ERROR", msg, e, fields);

    static void Write(string level, string msg, Exception? e, (string Key, object? Value)[] fields) =>
        Console.Out.WriteLine(Build(level, msg, e, fields));

    // 예외는 error(메시지)·stack(스택 트레이스) 필드 하나씩에 담아 여러 줄로 쪼개지지 않게 한다
    public static string Build(string level, string msg, Exception? e, IEnumerable<(string Key, object? Value)> fields)
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms, Options))
        {
            w.WriteStartObject();
            w.WriteString("ts", DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"));
            w.WriteString("level", level);
            w.WriteString("service", Service);
            w.WriteString("msg", msg);
            foreach (var (key, value) in fields)
            {
                switch (value)
                {
                    case null: break;
                    case int i: w.WriteNumber(key, i); break;
                    case long l: w.WriteNumber(key, l); break;
                    case double d: w.WriteNumber(key, d); break;
                    case bool b: w.WriteBoolean(key, b); break;
                    default: w.WriteString(key, value.ToString()); break;
                }
            }
            if (e != null)
            {
                w.WriteString("error", $"{e.GetType().FullName}: {e.Message}");
                w.WriteString("stack", e.ToString());
            }
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(ms.ToArray());
    }
}

// ASP.NET 프레임워크가 남기는 로그(경고 이상)도 같은 JSON 모양으로
sealed class JsonLogFormatter : ConsoleFormatter
{
    public JsonLogFormatter() : base("demo-json") { }

    public override void Write<TState>(in LogEntry<TState> entry, IExternalScopeProvider? scopeProvider, TextWriter textWriter)
    {
        var level = entry.LogLevel switch
        {
            LogLevel.Information => "INFO",
            LogLevel.Warning => "WARN",
            LogLevel.Error or LogLevel.Critical => "ERROR",
            _ => entry.LogLevel.ToString().ToUpperInvariant(),
        };
        var msg = entry.Formatter(entry.State, entry.Exception);
        textWriter.WriteLine(JsonLog.Build(level, msg, entry.Exception, new (string, object?)[] { ("category", entry.Category) }));
    }
}
