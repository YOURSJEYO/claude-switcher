using ClaudeSwitcher.App.Models;
using ClaudeSwitcher.App.Services;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

public sealed class SetupProtocolTests
{
    private const string ValidPreview = """
        {"schemaVersion":1,"success":true,"country":"JP","timeZoneId":"Tokyo Standard Time","culture":"ja-JP","proxyMode":"clash-verge","proxyGroup":"Synthetic Group"}
        """;

    private const string ValidApply = """
        {"schemaVersion":1,"success":true,"stage":"completed","code":"ok","message":"configuration complete"}
        """;

    [Fact]
    public void ParsePreview_AcceptsStrictReviewedShape()
    {
        var preview = SetupProtocolParser.ParsePreview(ValidPreview);

        Assert.Equal("JP", preview.Country);
        Assert.Equal("Tokyo Standard Time", preview.TimeZoneId);
        Assert.Equal("ja-JP", preview.Culture);
        Assert.Equal("clash-verge", preview.ProxyMode);
        Assert.Equal("Synthetic Group", preview.ProxyGroup);
        Assert.Equal(
            ["time zone", "IPv6", "DNS cache", "bodyguard task"],
            preview.ProposedEffects.Select(effect => effect.Id));
    }

    [Theory]
    [InlineData("""{"schemaVersion":1,"success":true,"country":"JP","timeZoneId":"Tokyo Standard Time","culture":"ja-JP","proxyMode":"clash-verge"}""")]
    [InlineData("""{"schemaVersion":1,"success":true,"country":"JP","timeZoneId":"Tokyo Standard Time","culture":"ja-JP","proxyMode":"clash-verge","proxyGroup":"Synthetic Group","extra":true}""")]
    [InlineData("""{"schemaVersion":1,"success":"true","country":"JP","timeZoneId":"Tokyo Standard Time","culture":"ja-JP","proxyMode":"clash-verge","proxyGroup":"Synthetic Group"}""")]
    [InlineData("""{"schemaVersion":2,"success":true,"country":"JP","timeZoneId":"Tokyo Standard Time","culture":"ja-JP","proxyMode":"clash-verge","proxyGroup":"Synthetic Group"}""")]
    [InlineData("""{"schemaVersion":1,"success":false,"country":"JP","timeZoneId":"Tokyo Standard Time","culture":"ja-JP","proxyMode":"clash-verge","proxyGroup":"Synthetic Group"}""")]
    public void ParsePreview_RejectsMissingExtraWrongTypeWrongSchemaOrFailure(string json)
    {
        Assert.Throws<SetupProtocolException>(() => SetupProtocolParser.ParsePreview(json));
    }

    [Theory]
    [InlineData("CN", "Tokyo Standard Time", "ja-JP", "clash-verge", "Synthetic Group")]
    [InlineData("ZZ", "Tokyo Standard Time", "ja-JP", "clash-verge", "Synthetic Group")]
    [InlineData("JP", "Not/A-Time-Zone", "ja-JP", "clash-verge", "Synthetic Group")]
    [InlineData("JP", "Tokyo Standard Time", "not-a-culture", "clash-verge", "Synthetic Group")]
    [InlineData("JP", "Tokyo Standard Time", "ja-JP", "powershell", "Synthetic Group")]
    [InlineData("JP", "Tokyo Standard Time", "ja-JP", "clash-verge", "unsafe\u0001group")]
    [InlineData("JP", "Tokyo Standard Time", "ja-JP", "clash-verge", "")]
    public void ParsePreview_RejectsUnsafeOrUnsupportedReviewedValues(
        string country,
        string timeZoneId,
        string culture,
        string proxyMode,
        string proxyGroup)
    {
        var json = System.Text.Json.JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            success = true,
            country,
            timeZoneId,
            culture,
            proxyMode,
            proxyGroup
        });

        Assert.Throws<SetupProtocolException>(() => SetupProtocolParser.ParsePreview(json));
    }

    [Fact]
    public void ParsePreview_RejectsDuplicateFieldsAndTrailingJson()
    {
        var duplicate = """
            {"schemaVersion":1,"success":true,"country":"JP","country":"US","timeZoneId":"Tokyo Standard Time","culture":"ja-JP","proxyMode":"clash-verge","proxyGroup":"Synthetic Group"}
            """;
        var trailing = ValidPreview + " {}";

        Assert.Throws<SetupProtocolException>(() => SetupProtocolParser.ParsePreview(duplicate));
        Assert.Throws<SetupProtocolException>(() => SetupProtocolParser.ParsePreview(trailing));
    }

    [Theory]
    [InlineData("""{"schemaVersion":1,"success":true,"stage":"system","code":"ok","message":"wrong stage"}""")]
    [InlineData("""{"schemaVersion":1,"success":true,"stage":"completed","code":"partial","message":"wrong code"}""")]
    public void ParseApply_RejectsSuccessUnlessCompletedOk(string json)
    {
        Assert.Throws<SetupProtocolException>(() => SetupProtocolParser.ParseApply(json));
    }
    [Fact]
    public void ParseApply_AcceptsStrictResultShape()
    {
        var result = SetupProtocolParser.ParseApply(ValidApply);

        Assert.True(result.Success);
        Assert.Equal("completed", result.Stage);
        Assert.Equal("ok", result.Code);
        Assert.Equal("configuration complete", result.Message);
    }

    [Theory]
    [InlineData("""{"schemaVersion":1,"success":true,"stage":"completed","code":"ok"}""")]
    [InlineData("""{"schemaVersion":1,"success":true,"stage":"completed","code":"ok","message":"done","extra":1}""")]
    [InlineData("""{"schemaVersion":1,"success":"true","stage":"completed","code":"ok","message":"done"}""")]
    [InlineData("""{"schemaVersion":1,"success":true,"stage":"","code":"ok","message":"done"}""")]
    public void ParseApply_RejectsMissingExtraWrongTypeOrEmptyStage(string json)
    {
        Assert.Throws<SetupProtocolException>(() => SetupProtocolParser.ParseApply(json));
    }
}