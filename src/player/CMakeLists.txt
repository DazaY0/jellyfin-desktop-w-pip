add_sources(PlayerComponent.cpp PlayerComponent.h)
add_sources(AlbumArtProvider.cpp AlbumArtProvider.h)
add_sources(MpvVideoItem.cpp MpvVideoItem.h)
add_sources(OpenGLDetect.cpp OpenGLDetect.h)
add_sources(QtHelper.h)

if(APPLE)
  add_sources(osx/MacPiPController.h osx/MacPiPController.mm)
endif()
