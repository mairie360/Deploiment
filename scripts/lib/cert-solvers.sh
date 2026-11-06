# shellcheck shell=bash
# Helper of scripts/verify.sh (sourced), step 12c (MAIR-795).
#
# cert-manager copies the Ingress annotation
# `acme.cert-manager.io/http01-ingress-ingressclassname` onto the Certificate it
# creates (as `acme.cert-manager.io/http01-override-ingress-ingressclassname`)
# ONCE, when it creates it, and never updates it. A Certificate created before
# that annotation existed, or while the machine ran another ingress controller,
# keeps the wrong class (or none): its HTTP-01 challenges then go to a class no
# controller serves, answer 404 forever and the renewal stalls without any alert
# (prod fronts, 2026-11-06). Deleting the Certificate makes cert-manager recreate
# it from the Ingress.

# Solver class cert-manager uses for a Certificate that carries no override: the
# `ingressClassName` of the ClusterIssuers' solver in
# bootstrap/cluster-addons/cluster-issuers.yaml. Keep both equal
# (tests/scripts/mair_795_cert_solver_test.sh checks it).
CLUSTER_ISSUER_DEFAULT_SOLVER="nginx"

# cert_solver_report <certificates.tsv> <ingresses.tsv>
#
#   certificates.tsv   name <TAB> owner Ingress <TAB> override annotation
#   ingresses.tsv      name <TAB> acme.cert-manager.io/http01-ingress-ingressclassname
#
# One line per Certificate on stdout, tab-separated:
#   OK    <cert> <ingress> <class>
#   FAIL  <cert> <ingress> <expected class> <class in use> <annotation|default>
#   SKIP  <cert> <reason>
# A Certificate its Ingress does not own (created by hand) or whose Ingress is
# gone is skipped: there is no class to compare it with. An Ingress without the
# annotation asks for the ClusterIssuer default.
cert_solver_report() {
  awk -F'\t' -v def="$CLUSTER_ISSUER_DEFAULT_SOLVER" '
    FILENAME == ARGV[1] { known[$1] = 1; want[$1] = $2; next }
    {
      name = $1; owner = $2; got = $3
      if (owner == "")          { print "SKIP\t" name "\tnot created from an Ingress"; next }
      if (!(owner in known))    { print "SKIP\t" name "\tIngress " owner " not found"; next }
      expected = (want[owner] == "" ? def : want[owner])
      inuse    = (got == "" ? def : got)
      how      = (got == "" ? "default" : "annotation")
      if (inuse == expected) print "OK\t" name "\t" owner "\t" inuse
      else                   print "FAIL\t" name "\t" owner "\t" expected "\t" inuse "\t" how
    }
  ' "$2" "$1"
}
