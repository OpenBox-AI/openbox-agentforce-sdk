/**
 * The four verdicts OpenBox Core emits on the wire (lowercase there). CONSTRAIN is defined in the
 * OpenBox specification but never produced by Core, so it is deliberately not representable:
 * receiving it is a contract violation and fails closed.
 */
public enum OpenBoxVerdict {
    ALLOW,
    REQUIRE_APPROVAL,
    BLOCK,
    HALT
}
