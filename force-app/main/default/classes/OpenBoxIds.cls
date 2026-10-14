/**
 * Identifier and clock helpers that follow the OpenBox wire rules:
 * span ids are 16 lowercase hex characters, trace ids 32, span times are epoch nanoseconds,
 * and event timestamps are RFC 3339 UTC with millisecond precision and a trailing Z.
 */
public inherited sharing class OpenBoxIds {
    private static final Long NANOS_PER_MILLI = 1000000L;

    private OpenBoxIds() {
    }

    public static String newRequestId() {
        return UUID.randomUUID().toString();
    }

    public static String newTraceId() {
        return randomHex(16);
    }

    public static String newSpanId() {
        return randomHex(8);
    }

    public static Long nowNanos() {
        return toNanos(Datetime.now());
    }

    public static Long toNanos(Datetime value) {
        return value.getTime() * NANOS_PER_MILLI;
    }

    private static Long lastIssuedMillis = 0;

    /**
     * Event time, strictly increasing within a transaction. OpenBox orders a session by event
     * timestamp, and events built in the same commit would otherwise share a millisecond and lose
     * their order.
     */
    public static String timestamp() {
        lastIssuedMillis = Math.max(Datetime.now().getTime(), lastIssuedMillis + 1);
        return timestamp(Datetime.newInstance(lastIssuedMillis));
    }

    public static String timestamp(Datetime value) {
        return value.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'');
    }

    public static Datetime parseTimestamp(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return (Datetime) JSON.deserialize('"' + value + '"', Datetime.class);
        } catch (JSONException e) {
            throw new OpenBoxContractException('Unparseable timestamp from OpenBox: ' + value);
        } catch (TypeException e) {
            throw new OpenBoxContractException('Unparseable timestamp from OpenBox: ' + value);
        }
    }

    private static String randomHex(Integer byteCount) {
        String hex = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        String candidate = hex.substring(0, byteCount * 2);
        // The all-zero id is reserved as "invalid" by OpenTelemetry; regenerate in that (vanishingly rare) case.
        return candidate.replace('0', '').length() == 0 ? randomHex(byteCount) : candidate;
    }
}
