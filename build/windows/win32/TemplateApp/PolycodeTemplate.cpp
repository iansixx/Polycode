#include <Polycode.h>
#include <polycode/view/win/core/PolycodeView.h>
#include "PolycodeTemplateApp.h"
#include "windows.h"

using namespace Polycode;

int APIENTRY WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow)
{
	PolycodeView *view = new PolycodeView(hInstance, nCmdShow, L"Polycode Template", false, true);
	PolycodeTemplateApp *app = new PolycodeTemplateApp(view);

	MSG Msg;
	do {
		if (view->changed) {
			view->handleChange();
		}

		while (PeekMessage(&Msg, NULL, 0, 0, PM_REMOVE)) {
			TranslateMessage(&Msg);
			DispatchMessage(&Msg);
		}
	} while(app->Update());
	return Msg.wParam;
}