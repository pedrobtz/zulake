# file names in _delta_log
from tk import *
def base(name, n=3):
    d = new(name); adds = []
    for i in range(n):
        a = data(d, "f%d.parquet" % i, {"id": [i]}); adds.append(a)
        commit(d, i, ([ci(), proto(), meta()] if i == 0 else [ci()]) + [a])
    return d, adds
R = [ci(), rm("f0.parquet")]
d, A = base("l_19"); commit(d, 0, R, name="0000000000000000003.json")          # 19 digits
d, A = base("l_21"); commit(d, 0, R, name="000000000000000000003.json")        # 21 digits
d, A = base("l_upper"); commit(d, 0, R, name="00000000000000000003.JSON")
d, A = base("l_tmp"); commit(d, 0, R, name="00000000000000000003.json.tmp")
d, A = base("l_uuid"); commit(d, 0, R, name="00000000000000000003.aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb.json")
d, A = base("l_staged"); os.makedirs(d + "/_delta_log/_staged_commits"); commit(d, 0, R, name="_staged_commits/00000000000000000003.aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb.json")
d, A = base("l_dir"); os.makedirs(d + "/_delta_log/00000000000000000003.json")
d, A = base("l_crc"); commit(d, 0, [], name="00000000000000000002.crc", raw="not json at all")
d, A = base("l_gz"); commit(d, 0, R, name="00000000000000000003.json.gz")
# V2-like names
d, A = base("l_v2dash"); commit(d, 0, [proto(), meta(), data(d, "mark.parquet", {"id": [777]})], name="00000000000000000002.checkpoint.%s.json" % ("-" * 36))
d, A = base("l_v2upper"); commit(d, 0, [proto(), meta(), data(d, "mark.parquet", {"id": [777]})], name="00000000000000000002.checkpoint.AAAAAAAA-1111-4222-8333-BBBBBBBBBBBB.json")
d, A = base("l_v2noproto"); commit(d, 0, [proto(), meta(), data(d, "mark.parquet", {"id": [777]})], name="00000000000000000002.checkpoint.aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb.json")
# multipart oddities
d, A = base("l_mp1of1"); write_cp(d, mpname(2, 1, 1), [proto(), meta(), data(d, "mark.parquet", {"id": [777]})])
d, A = base("l_mp3of2"); write_cp(d, mpname(2, 1, 2), [proto(), meta(), data(d, "mark.parquet", {"id": [777]})]); write_cp(d, mpname(2, 3, 2), [A[1]])
d, A = base("l_mp2sets"); write_cp(d, mpname(2, 1, 2), [proto(), meta(), data(d, "mark2.parquet", {"id": [222]})]); write_cp(d, mpname(2, 2, 2), [A[1]]); write_cp(d, mpname(2, 1, 3), [proto(), meta(), data(d, "mark3.parquet", {"id": [333]})]); write_cp(d, mpname(2, 2, 3), [A[1]]); write_cp(d, mpname(2, 3, 3), [A[2]])
d, A = base("l_mp_empty_part"); write_cp(d, mpname(2, 1, 2), [proto(), meta(), data(d, "mark.parquet", {"id": [777]})]); write_cp(d, mpname(2, 2, 2), [])
# big versions
def big(name, cpv, commits):
    d = new(name); m = data(d, "mark.parquet", {"id": [777]})
    write_cp(d, cpname(cpv), [proto(), meta(), m])
    for v in commits: commit(d, v, [ci(), data(d, "g%d.parquet" % (v % 1000), {"id": [v % 1000]})])
    return d
M = 2**53
big("l_big_ok", M - 3, [M - 2, M - 1]); big("l_big_over", M - 3, [M - 2, M - 1, M]); big("l_big_cp", M - 1, []); big("l_big_cpover", M, [])
big("l_e15", 10**15, [10**15 + 1]); big("l_max20", 10**19, [])
# _last_checkpoint shapes
def lc(name, text):
    d, A = base(name); write_cp(d, cpname(2), [proto(), meta(), data(d, "mark.parquet", {"id": [777]})]); open(d + "/_delta_log/_last_checkpoint", "w").write(text)
lc("lc_ok", '{"version":2,"size":3}'); lc("lc_str", '{"version":"2"}'); lc("lc_frac", '{"version":2.0}'); lc("lc_exp", '{"version":2e0}'); lc("lc_neg", '{"version":-1}'); lc("lc_empty", ''); lc("lc_trunc", '{"version":2,"si')
lc("lc_old", '{"version":1}'); lc("lc_parts", '{"version":2,"size":3,"parts":5}'); lc("lc_size", '{"version":2,"size":-7,"sizeInBytes":1.5,"numOfAddFiles":"x"}'); lc("lc_arr", '[{"version":2}]'); lc("lc_two", '{"version":2}\n{"version":0}'); lc("lc_ws", '\n\n  {"version":2}\n\n')
lc("lc_zero", '{"version":0}'); lc("lc_big", '{"version":9007199254740993}')
