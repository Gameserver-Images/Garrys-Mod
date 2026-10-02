###########################################################
# Dockerfile that builds a Garry's Mod Gameserver
###########################################################
FROM cm2network/steamcmd:root

ENV STEAMAPPID=4020
ENV STEAMAPP=gmod
ENV STEAMAPPDIR="${HOMEDIR}/${STEAMAPP}-dedicated"
# Fix for a new installation problem in the Steamcmd client
ENV HOME="${HOMEDIR}"

# Created here so a new named volume starts out owned by the steam user. The addons, data and
# gamemodes folders already exist, so a folder mounted into one of them doesn't make Docker create
# its parents as root.
RUN mkdir -p "${STEAMAPPDIR}/garrysmod/addons" "${STEAMAPPDIR}/garrysmod/data" "${STEAMAPPDIR}/garrysmod/gamemodes" \
  && chown -R "${USER}:${USER}" "${HOMEDIR}"

COPY --chmod=755 scripts /server/scripts
# image-env lists the variables the image sets itself, so startup can warn about unknown ones.
RUN ln -s /server/scripts/list_env.sh /usr/local/bin/list-env \
  && ln -s /server/scripts/console.sh /usr/local/bin/console \
  && ln -s /server/scripts/server_info.sh /usr/local/bin/server-info \
  && env | cut -d= -f1 | sort > /server/scripts/image-env

USER ${USER}
WORKDIR ${HOMEDIR}

EXPOSE 27015/udp \
  27015/tcp

# The first start downloads the game, mounted games and the workshop collection; the check only
# counts once the server answers queries.
HEALTHCHECK --start-period=30m --interval=30s --timeout=10s --retries=3 \
  CMD ["/server/scripts/healthcheck.sh"]

ENTRYPOINT ["/server/scripts/entry.sh"]
